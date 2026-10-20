import AppKit
import SwiftUI

/// 点选首页的文件时先把键盘焦点从搜索框拿开：首页的格子点了不拿焦点，搜索框还拿着的话，
/// ⌘⌫ 会交给输入框（删到行首），文件删不掉。
@MainActor
private func releaseTextFocus() {
    guard let window = NSApp.keyWindow, window.firstResponder is NSText else { return }
    window.makeFirstResponder(nil)
}

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

    /// 首页顶部的「最近使用」：把几个货架里的文件合在一起，按最近打开/加入/修改排序。
    private var recentItems: [FileItem] {
        var seen = Set<String>()
        return store.shelves.flatMap(\.items)
            .sorted { $0.recentDate > $1.recentDate }
            .filter { seen.insert($0.id).inserted }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                TrialEndingBanner()
                header
                if !recentItems.isEmpty { recentSection }
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
            // 点空白处取消选中（和访达一样），也把键盘焦点从搜索框拿开。
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        releaseTextFocus()
                        if !store.selectedIDs.isEmpty { store.selectedIDs = [] }
                    }
            )
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("首页")
        // 点选了「最近使用」或下面货架里的文件后，⌘⌫ 把它移到废纸篓（和访达一样）。
        .trashContext(ids: store.selectedIDs) {
            let ids = store.selectedIDs
            guard !ids.isEmpty else { return [] }
            var seen = Set<String>()
            return store.shelves.flatMap(\.items).filter { ids.contains($0.id) && seen.insert($0.id).inserted }
        }
        .task {
            // 回到首页时重新算一下：应用一直开着时，也能在到期前一天出现横幅。
            LicenseManager.shared.refreshState()
            await TrialReminder.shared.update()
        }
    }

    private func select(_ item: FileItem) {
        releaseTextFocus()
        store.selectedIDs = [item.id]
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                Text(greeting)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Button {
                    // 走 reload：和切页面共用一个任务，连点只算最后一次。
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("重新统计")
                .accessibilityLabel("刷新")
            }
            if totalCount > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CountingNumber(value: Double(totalCount))
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                    Text("个文件，共 \(totalBytes.byteText)")
                        .foregroundStyle(.secondary)
                    if !store.todayAdded.isEmpty {
                        TodayAddedChip()
                            .padding(.leading, 6)
                    }
                }
            } else {
                Text("正在读取 Spotlight 索引…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 最近使用

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "最近使用"), action: { store.selection = .category(.recents) })
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(recentItems) { item in
                        RecentTile(item: item, selected: store.selectedIDs.contains(item.id))
                            .onTapGesture(count: 2) { store.openItems([item]) }
                            .onTapGesture { select(item) }
                            // 键盘 / VoiceOver：读出文件名，是可以按的；默认动作是打开。
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(store.selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { store.openItems([item]) }
                            .contextMenu { FileContextMenu(items: [item]) }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                            .help(item.path)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - 资料库

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "资料库"), count: FileCategory.dashboard.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 12) {
                ForEach(FileCategory.dashboard) { category in
                    Button { store.selection = .category(category) } label: {
                        LibraryTile(category: category, total: store.totals[category], previews: store.previews[category] ?? [])
                    }
                    .buttonStyle(.plain)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 12) {
                Button { store.selection = .duplicates } label: { DuplicatesTile() }
                    .buttonStyle(.plain)
                if cleanup.isRunning && cleanup.cards.isEmpty {
                    placeholderTile(String(localized: "正在找可以清理的文件…"))
                } else if cleanup.hasScanned && cleanupCards.isEmpty {
                    placeholderTile(String(localized: "没有需要清理的，很整齐"))
                }
                ForEach(cleanupCards.prefix(3)) { card in
                    Button { store.openCleanup(card.kind) } label: { CleanupTile(card: card) }
                        .buttonStyle(.plain)
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
        .frame(maxWidth: .infinity, minHeight: 84)
        .glassCard()
    }

    // MARK: - 下载来源

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "下载来源"), count: store.sourceGroups.count, action: { store.openDownloads(source: nil) })
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(store.sourceGroups.prefix(8)) { group in
                    Button { store.openDownloads(source: group.source.id) } label: { SourceTile(group: group) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 卡片

/// 资料库分类卡片：一行矮卡片，左边彩色图标和数量，右边三张斜叠的最近文件。
struct LibraryTile: View {
    let category: FileCategory
    let total: CategoryTotal?
    let previews: [FileItem]

    var body: some View {
        HStack(spacing: 14) {
            TintedIcon(symbol: category.symbol, tint: category.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.system(.headline, design: .rounded))
                Text(total.map { String(localized: "\($0.count) 个 · \($0.bytes.byteText)") } ?? String(localized: "统计中…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if total == nil {
                ProgressView().controlSize(.small)
            } else {
                FannedThumbnails(items: previews, total: total?.count ?? 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .glassCard(tint: category.tint, radius: 18, interactive: true)
    }
}

/// 清理卡片：标题、能腾出的空间，右边一个「清理」按钮（点卡片任何地方都进入清理）。
struct CleanupTile: View {
    let card: CleanupCard

    var body: some View {
        CompactCleanupTile(
            symbol: card.kind.symbol, tint: card.kind.tint, title: card.kind.title,
            value: card.bytes.byteText, detail: String(localized: "\(card.items.count) 个项目")
        )
    }
}

struct CompactCleanupTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    var detail: String = ""
    var progress: Double? = nil

    var body: some View {
        HStack(spacing: 12) {
            TintedIcon(symbol: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            if let progress {
                ProgressView(value: progress).frame(width: 54)
            } else {
                Text("清理")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .glassCard(tint: tint, radius: 18, interactive: true)
    }
}

struct DuplicatesTile: View {
    @EnvironmentObject private var scanner: DuplicateScanner
    private let tint = Color(red: 0.95, green: 0.45, blue: 0.45)

    private var extraCopies: Int {
        scanner.groups.reduce(0) { $0 + max($1.items.count - 1, 0) }
    }

    var body: some View {
        CompactCleanupTile(
            symbol: "doc.on.doc", tint: tint, title: String(localized: "重复文件"),
            value: scanner.hasScanned
                ? scanner.reclaimable.byteText
                : (scanner.isRunning ? String(localized: "扫描中…") : String(localized: "点按扫描")),
            detail: scanner.hasScanned ? String(localized: "多出 \(extraCopies) 份") : "",
            progress: scanner.isRunning ? scanner.progress : nil
        )
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
                            ThumbnailView(url: item.url, size: 104, modified: item.modified)
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
                        .onTapGesture(count: 2) { store.openItems([item]) }
                        .onTapGesture {
                            releaseTextFocus()
                            store.selectedIDs = [item.id]
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(store.selectedIDs.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { store.openItems([item]) }
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

/// 首页「最近使用」里的一格：宽缩略图 + 文件名。
struct RecentTile: View {
    let item: FileItem
    var selected = false

    var body: some View {
        VStack(spacing: 7) {
            ThumbnailView(url: item.url, size: 132, fill: true, modified: item.modified)
                .frame(width: 132, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 128)
        }
    }
}

/// 三张斜着叠在一起的最近文件缩略图，右下角挂「+N」。
struct FannedThumbnails: View {
    let items: [FileItem]
    var total: Int = 0
    var size: CGFloat = 34

    private static let angles: [Double] = [-12, -3, 8]

    var body: some View {
        let shown = Array(items.prefix(3))
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    ThumbnailView(url: item.url, size: size, fill: true, modified: item.modified)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(2)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1.5)
                        .rotationEffect(.degrees(Self.angles[index]))
                        .offset(x: CGFloat(index) * size * 0.58)
                }
            }
            .frame(width: size * 2.3, height: size + 10, alignment: .leading)
            let extra = total - shown.count
            if extra > 0 {
                Text(extra > 99 ? "+99" : "+\(extra)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .offset(x: 6, y: 4)
            }
        }
        .accessibilityHidden(true)
    }
}
