import SwiftUI

/// 清理页：大号数字的卡片（重复文件也是一张），点进去是审阅页。
struct CleanupView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scanner: CleanupScanner
    @EnvironmentObject private var duplicates: DuplicateScanner

    private var cards: [CleanupCard] {
        scanner.cards.filter { !$0.items.isEmpty && $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    private var total: Int64 { scanner.totalBytes + duplicates.reclaimable }

    var body: some View {
        Group {
            if let kind = store.cleanupReview {
                CleanupReviewPage(kind: kind)
            } else {
                overview
            }
        }
        .navigationTitle("清理")
        .task {
            if !Demo.isOn, !scanner.hasScanned, !scanner.isRunning { await scanner.scan() }
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("清理")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("重复文件、旧安装包、被遗忘的下载，一次看清")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await scanner.scan() }
                    } label: {
                        HStack(spacing: 6) {
                            if scanner.isRunning { ProgressView().controlSize(.small) }
                            Label("重新扫描", systemImage: "arrow.clockwise")
                        }
                        .glassCapsule()
                    }
                    .buttonStyle(.plain)
                    .disabled(scanner.isRunning)
                }

                FreeUpHero(bytes: total, scanning: scanner.isRunning || duplicates.isRunning)

                // 用户来清理页就是想看「能清掉什么」：清理卡片放最前面，Pro 的工具放在后面。
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    Button { store.selection = .duplicates } label: { DuplicatesTile() }
                        .buttonStyle(.plain)
                    ForEach(cards) { card in
                        Button { store.cleanupReview = card.kind } label: { CleanupTile(card: card) }
                            .buttonStyle(.plain)
                    }
                }

                Label("以上清理不会直接删除，都进废纸篓，随时可以放回原处。只在 iCloud 云端的文件会被跳过。", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("更多工具")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 6)

                AppUninstallRow()

                AutoOrganizeLinkRow()
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
    }
}

/// 清理页的页内标签：概览 / 空间占用 / 清理记录 / 自动整理（侧边栏「整理」里只留「清理」一行，这几个页面在这里切换）。
struct CleanupTabs<Content: View>: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview, storage, history, organize
        var id: Self { self }

        var item: SidebarItem {
            switch self {
            case .overview: return .cleanup
            case .storage: return .storageMap
            case .history: return .cleanupHistory
            case .organize: return .autoOrganize
            }
        }

        var title: String {
            switch self {
            case .overview: return String(localized: "概览")
            case .storage: return String(localized: "空间占用")
            case .history: return String(localized: "清理记录")
            case .organize: return String(localized: "自动整理")
            }
        }

        static func of(_ item: SidebarItem?) -> Tab? {
            allCases.first { $0.item == item }
        }
    }

    private var tab: Binding<Tab> {
        Binding(get: { Tab.of(store.selection) ?? .overview },
                set: { new in
                    store.cleanupReview = nil
                    store.selection = new.item
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("清理", selection: tab) {
                ForEach(Tab.allCases) { tab in
                    Text(verbatim: tab == .organize && !license.isPro ? "\(tab.title) · Pro" : tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 2)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 清理页「更多工具」里的一行：自动整理（自动清理用过的安装包也是那里的一条规则）。
private struct AutoOrganizeLinkRow: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var organizer: AutoOrganizer
    @EnvironmentObject private var license: LicenseManager

    var body: some View {
        Button {
            store.selection = .autoOrganize
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("自动整理")
                            .font(.headline)
                        ProBadge()
                            .opacity(license.isPro ? 0.55 : 1)
                    }
                    Text(organizer.autoCleansInstallers
                         ? String(localized: "已开启「自动清理用过的安装包」。按规则自动把下载里的文件归类或移到废纸篓。")
                         : String(localized: "按规则自动把下载里的文件归类或移到废纸篓，比如自动清理用过的安装包。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
            .glassCard(radius: 16)
        }
        .buttonStyle(.plain)
    }
}

/// 「自动清理用过的安装包」开关（Pro，默认关闭）：自动整理里的一条现成规则，只移到废纸篓。放在自动整理页上面。
struct AutoCleanInstallersRow: View {
    @EnvironmentObject private var organizer: AutoOrganizer
    @EnvironmentObject private var license: LicenseManager

    /// 显示规则里真实的天数；规则还没建时显示默认的 14 天。
    private var days: Int {
        guard let rule = organizer.installerRule else { return AutoOrganizer.installerDefaultDays }
        return max(rule.olderThanDays ?? 0, 0)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("自动清理用过的安装包")
                        .font(.headline)
                    ProBadge()
                        .opacity(license.isPro ? 0.55 : 1)
                }
                (days > 0
                     ? Text("“下载”里超过 \(days) 天的 .dmg / .pkg 自动移到废纸篓，30 天内可以在「清理记录」里放回。拾掇开着时每 10 分钟检查一次。")
                     : Text("“下载”里所有 .dmg / .pkg 都会移到废纸篓（这条规则没设天数，可以在下面的规则里改）。30 天内可以在「清理记录」里放回。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("自动清理用过的安装包", isOn: Binding(
                get: { license.isPro && organizer.autoCleansInstallers },
                set: { on in
                    if on {
                        guard license.isPro else {
                            license.showPaywall = true
                            return
                        }
                    }
                    organizer.setAutoCleanInstallers(on)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(14)
        .glassCard(radius: 16)
    }
}

/// 一张清理卡片的审阅页：缩略图网格，可以全部移到废纸篓，也可以只移除选中的。
struct CleanupReviewPage: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scanner: CleanupScanner
    let kind: CleanupKind

    @State private var selected: Set<String> = []
    @State private var confirm: [FileItem] = []

    private var card: CleanupCard? { scanner.cards.first { $0.kind == kind } }
    private var items: [FileItem] { card?.items ?? [] }
    private var selectedItems: [FileItem] { items.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Button {
                        store.cleanupReview = nil
                    } label: {
                        Label("清理", systemImage: "chevron.left")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    HStack(alignment: .center, spacing: 16) {
                        TintedIcon(symbol: kind.symbol, tint: kind.tint, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text(kind.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text((card?.bytes ?? 0).byteText)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            Text("\(items.count) 个项目")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(22)
                    .glassCard(tint: kind.tint)

                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 34))
                                .foregroundStyle(.green)
                            Text("已经清理完了")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(items) { item in
                                ReviewCell(item: item, selected: selected.contains(item.id))
                                    .onTapGesture(count: 2) { store.openItems([item]) }
                                    .onTapGesture { toggle(item) }
                                    .contextMenu { FileContextMenu(items: [item]) }
                                    .onDrag { InAppDrag.copyOnlyProvider(item.url) }
                                    .help(item.path)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: 12) {
                Button(selected.count == items.count && !items.isEmpty ? String(localized: "取消全选") : String(localized: "全选")) {
                    selected = selected.count == items.count ? [] : Set(items.map(\.id))
                }
                .disabled(items.isEmpty)
                Text(selected.isEmpty ? String(localized: "点缩略图选择要移到废纸篓的文件") : String(localized: "已选 \(selected.count) 项 · \(selectedBytes.byteText)"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.requestMoveOut(selected.isEmpty ? items : selectedItems)
                } label: {
                    HStack(spacing: 4) {
                        Text(selected.isEmpty ? String(localized: "全部大文件搬家…") : String(localized: "大文件搬家…"))
                        ProBadge()
                    }
                }
                .disabled(items.isEmpty)
                .help("搬到移动硬盘、NAS 或网盘，不删除")
                Button("把所选移到废纸篓") { trash(selectedItems) }
                    .disabled(selected.isEmpty)
                Button {
                    trash(items)
                } label: {
                    Label("全部移到废纸篓", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(items.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        // ⌘⌫ 把点选的直接移到废纸篓（和访达一样不确认，小提示上可以撤销）；底部按钮也一样，只有大批量才先确认。
        .trashContext(ids: selected, items: { selectedItems }) { list in
            store.moveToTrash(list)
            selected.subtract(list.map(\.id))
        }
        .confirmationDialog(
            "将 \(confirm.count) 个项目移到废纸篓？",
            isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                let list = confirm
                confirm = []
                store.moveToTrash(list)
                selected.subtract(list.map(\.id))
            }
            Button("取消", role: .cancel) { confirm = [] }
        } message: {
            Text("随时可以从废纸篓里恢复。只在 iCloud 云端的文件会被跳过。")
        }
    }

    /// 少量的直接移到废纸篓（小提示上可以撤销）；大批量（≥100 个或 ≥5 GB）先确认。
    private func trash(_ list: [FileItem]) {
        guard !list.isEmpty else { return }
        let size = LibraryStore.trashSize(list)
        if TrashConfirm.needsConfirm(count: list.count, bytes: size.bytes, unknownFolderSize: size.unknownFolder) {
            confirm = list
        } else {
            store.moveToTrash(list)
            selected.subtract(list.map(\.id))
        }
    }

    private func toggle(_ item: FileItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
}

struct ReviewCell: View {
    let item: FileItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ThumbnailView(url: item.url, size: 120, modified: item.modified, isFolder: item.isPlainFolder)
                    .frame(width: 130, height: 120)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(Circle().fill(.background).padding(2))
            }
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 140)
            Text("\(item.sizeText) · \(item.relativeDateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}
