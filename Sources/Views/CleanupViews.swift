import SwiftUI

/// 清理页：大号数字的卡片（重复文件也是一张），点进去是审阅页。
struct CleanupView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var scanner: CleanupScanner
    @EnvironmentObject private var duplicates: DuplicateScanner
    @ObservedObject private var fonts = FontLibrary.shared

    /// 放心清里用户改过勾选的卡片（没改过的按卡片自己的默认：开发缓存 / 已装应用的安装包勾，邮件附件副本不勾）。
    @State private var safeOverrides: [CleanupKind: Bool] = [:]
    /// 放心清里「重复文件的多余副本」：默认不勾，用户自己勾。
    @State private var duplicatesChecked = false
    @State private var confirmSafe: [FileItem] = []
    @State private var confirmDuplicates: [FileGroup] = []
    @State private var showConfirmSafe = false

    private var cards: [CleanupCard] {
        scanner.cards.filter { !$0.items.isEmpty && $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
    }

    private var safeCards: [CleanupCard] { cards.filter { $0.kind.group == .safe } }
    private var reviewCards: [CleanupCard] { cards.filter { $0.kind.group == .review } }
    private func isChecked(_ kind: CleanupKind) -> Bool { safeOverrides[kind] ?? kind.defaultChecked }
    private var checkedSafe: [CleanupCard] { safeCards.filter { isChecked($0.kind) } }
    private var checkedSafeItems: [FileItem] { checkedSafe.flatMap(\.items) }
    /// 重复文件：扫描过、有多余副本时才在放心清里出现一行（扫描中也显示进度）。
    private var showsDuplicateRow: Bool {
        duplicates.isRunning || (duplicates.hasScanned && duplicates.reclaimable > 0)
    }
    private var duplicatesIncluded: Bool {
        duplicatesChecked && duplicates.hasScanned && !duplicates.isRunning && duplicates.reclaimable > 0
    }
    private var confirmSafeCount: Int {
        confirmSafe.count + confirmDuplicates.reduce(0) { $0 + max($1.items.count - 1, 0) }
    }
    private var checkedSafeBytes: Int64 {
        checkedSafe.reduce(0) { $0 + $1.bytes } + (duplicatesIncluded ? duplicates.reclaimable : 0)
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
            guard !Demo.isOn else { return }
            // 重复文件在后台另外比对（「重复文件」页上可以停止）。
            if !duplicates.hasScanned, !duplicates.isRunning { duplicates.start() }
            // 字体只扫字体文件夹，很快；扫完「你来决定」里出现「字体」卡片。
            fonts.scanIfNeeded()
            if !scanner.hasScanned, !scanner.isRunning { await scanner.scan() }
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
                        if scanner.isRunning {
                            scanner.cancel()
                        } else {
                            Task { await scanner.scan() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if scanner.isRunning {
                                ProgressView().controlSize(.small)
                                Label("停止扫描", systemImage: "stop.fill")
                            } else {
                                Label("重新扫描", systemImage: "arrow.clockwise")
                            }
                        }
                        .glassCapsule()
                    }
                    .buttonStyle(.plain)
                }

                FreeUpHero(bytes: total, scanning: scanner.isRunning || duplicates.isRunning)

                DiskUsageBar(reclaimable: total)

                // 放心清：确认用过、能重新下载的，默认勾选，一键移到废纸篓。
                CleanupGroupHeader(
                    title: String(localized: "放心清"),
                    subtitle: String(localized: "确认用过或能重新下载的，默认勾选"),
                    symbol: "checkmark.seal.fill", tint: .green
                )
                if safeCards.isEmpty && !showsDuplicateRow {
                    Text(scanner.isRunning ? String(localized: "正在找…") : String(localized: "这一组没有要清的"))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                } else {
                    VStack(spacing: 10) {
                        ForEach(safeCards) { card in
                            SafeCleanupRow(
                                card: card,
                                checked: Binding(
                                    get: { isChecked(card.kind) },
                                    set: { safeOverrides[card.kind] = $0 }
                                ),
                                open: { store.cleanupReview = card.kind }
                            )
                        }
                        if showsDuplicateRow {
                            DuplicateSafeRow(checked: $duplicatesChecked) {
                                store.duplicatesTab = .exact
                                store.selection = .duplicates
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            trashSafe()
                        } label: {
                            Label(String(localized: "清理勾选的 \(checkedSafeBytes.byteText)"), systemImage: "trash")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .disabled(checkedSafeItems.isEmpty && !duplicatesIncluded)
                    }
                }

                // 你来决定：默认不勾，点进去逐个挑。
                CleanupGroupHeader(
                    title: String(localized: "你来决定"),
                    subtitle: String(localized: "可能还要用，默认不勾，点进去自己挑"),
                    symbol: "hand.raised.fill", tint: .orange
                )
                .padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    // 重复文件扫描过、有多余副本时在上面「放心清」里（默认不勾）；还没扫描 / 没有时留在这里当入口。
                    if !showsDuplicateRow {
                        Button {
                            store.duplicatesTab = .exact
                            store.selection = .duplicates
                        } label: { DuplicatesTile() }
                            .buttonStyle(.plain)
                    }
                    ForEach(reviewCards) { card in
                        Button { store.cleanupReview = card.kind } label: { CleanupTile(card: card, showsReason: true) }
                            .buttonStyle(.plain)
                    }
                    // 字体：重复、多版本、损坏的字体，默认不勾，点进去在字体页里挑；默认是「停用」（可以再启用），不是删除。
                    if fonts.actionableIssueCount > 0 || fonts.isScanning {
                        Button {
                            fonts.tab = .problems
                            store.selection = .fonts
                        } label: { FontsCleanupTile() }
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
        .confirmationDialog(
            "将 \(confirmSafeCount) 个项目移到废纸篓？",
            isPresented: $showConfirmSafe,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                let list = confirmSafe
                let dups = confirmDuplicates
                confirmSafe = []
                confirmDuplicates = []
                moveSafe(list, duplicates: dups)
            }
            Button("取消", role: .cancel) {
                confirmSafe = []
                confirmDuplicates = []
            }
        } message: {
            Text("随时可以从废纸篓里恢复。只在 iCloud 云端的文件会被跳过。")
        }
    }

    /// 少量直接移到废纸篓（小提示上可以撤销）；大批量（≥100 个或 ≥5 GB）先确认。
    private func trashSafe() {
        let list = checkedSafeItems
        let dups = duplicatesIncluded ? duplicates.groups : []
        guard !list.isEmpty || !dups.isEmpty else { return }
        let size = cleanupTrashSize(list)
        let dupCount = dups.reduce(0) { $0 + max($1.items.count - 1, 0) }
        let dupBytes = dups.reduce(Int64(0)) { $0 + ($1.items.first?.size ?? 0) * Int64(max($1.items.count - 1, 0)) }
        if TrashConfirm.needsConfirm(count: list.count + dupCount, bytes: size.bytes + dupBytes, unknownFolderSize: size.unknownFolder) {
            confirmSafe = list
            confirmDuplicates = dups
            showConfirmSafe = true
        } else {
            moveSafe(list, duplicates: dups)
        }
    }

    private func moveSafe(_ list: [FileItem], duplicates groups: [FileGroup]) {
        if !list.isEmpty {
            store.moveToTrash(list) { moved in
                scanner.remove(paths: moved)
            }
        }
        if !groups.isEmpty {
            // 每组留第一份（建议保留：最近打开过的），其余移走；移之前核对保留的那份还在、没变。
            store.trashDuplicateExtras(groups.map { (kept: Array($0.items.prefix(1)), extras: Array($0.items.dropFirst())) },
                                       exact: true)
            duplicatesChecked = false
        }
    }
}

/// 清理页里一组的标题：放心清 / 你来决定。
private struct CleanupGroupHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// 清理卡片要移到废纸篓的总大小：文件夹先用 FolderSizeStore 里算好的，没有就用扫描时算好的大小。
@MainActor
func cleanupTrashSize(_ list: [FileItem]) -> (bytes: Int64, unknownFolder: Bool) {
    var bytes: Int64 = 0
    var unknown = false
    for item in list {
        if item.isDirectory {
            if let known = FolderSizeStore.shared.knownSize(item.path) {
                bytes += known
            } else if item.size > 0 {
                bytes += item.size
            } else {
                unknown = true
            }
        } else {
            bytes += item.size
        }
    }
    return (bytes, unknown)
}

/// 标题旁的「新」小标签（智能清理进阶新加的卡片）。
struct NewBadge: View {
    var body: some View {
        Text("新")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green))
    }
}

/// 放心清里「重复文件的多余副本」一行：默认不勾；勾上后「清理勾选的」会把每组建议保留以外的副本移到废纸篓。
private struct DuplicateSafeRow: View {
    @EnvironmentObject private var duplicates: DuplicateScanner
    @Binding var checked: Bool
    let open: () -> Void

    private let tint = Color(red: 0.95, green: 0.45, blue: 0.45)
    private var extraCopies: Int { duplicates.groups.reduce(0) { $0 + max($1.items.count - 1, 0) } }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("重复文件的多余副本", isOn: $checked)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(duplicates.isRunning)
            TintedIcon(symbol: "doc.on.doc", tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("重复文件的多余副本")
                        .font(.headline)
                    NewBadge()
                }
                Text("每组保留最近打开的一份，其余移到废纸篓；默认不勾，可以点「查看」逐组挑")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if duplicates.isRunning {
                    ProgressView(value: duplicates.progress)
                        .frame(width: 80)
                    Text("正在比对…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(duplicates.reclaimable.byteText)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(extraCopies) 个多余副本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("查看", action: open)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .glassCard(tint: tint, radius: 16)
        .opacity(checked ? 1 : 0.6)
    }
}

/// 放心清的一行：勾选框、原因、能腾出的空间，「查看」进审阅页。
private struct SafeCleanupRow: View {
    let card: CleanupCard
    @Binding var checked: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(card.kind.title, isOn: $checked)
                .toggleStyle(.checkbox)
                .labelsHidden()
            TintedIcon(symbol: card.kind.symbol, tint: card.kind.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.kind.title)
                        .font(.headline)
                    if card.kind.isNew { NewBadge() }
                }
                Text(card.kind.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(card.bytes.byteText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("\(card.items.count) 个项目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("查看", action: open)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .glassCard(tint: card.kind.tint, radius: 16)
        .opacity(checked ? 1 : 0.6)
    }
}

/// 这台 Mac 的磁盘：已用多少、共多少，以及清理后能腾出多少（画在同一根条上）。
struct DiskUsageBar: View {
    let reclaimable: Int64
    @State private var total: Int64 = 0
    @State private var free: Int64 = 0

    private var used: Int64 { max(total - free, 0) }

    var body: some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("这台 Mac 已用 \(used.byteText)，共 \(total.byteText)")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("还剩 \(free.byteText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    let width = geo.size.width
                    let usedW = width * CGFloat(Double(used) / Double(total))
                    let freeUpW = min(usedW, width * CGFloat(Double(reclaimable) / Double(total)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: usedW)
                        Capsule().fill(Color.green).frame(width: freeUpW)
                            .offset(x: usedW - freeUpW)
                    }
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    Label("已用", systemImage: "circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Label("可以腾出 \(reclaimable.byteText)", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .labelStyle(DotLabelStyle())
            }
            .padding(16)
            .glassCard(radius: 16)
        } else {
            Color.clear.frame(height: 0)
                .task { load() }
        }
    }

    private func load() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        total = Int64(values.volumeTotalCapacity ?? 0)
        free = values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title.foregroundStyle(.secondary)
        }
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
                                ReviewCell(item: item, selected: selected.contains(item.id), label: card?.labels[item.path])
                                    .onTapGesture(count: 2) { store.openItems([item]) }
                                    .onTapGesture { toggle(item) }
                                    .stableContextMenu { FileContextMenu(items: [item]) }
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
                if kind.allowsMoveOut {
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
                }
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
        let size = cleanupTrashSize(list)
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
    /// 换个显示名字（node_modules 显示项目名、残留显示 Bundle ID……）；nil 用文件名。
    var label: CleanupItemLabel? = nil

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
            Text(label?.title ?? item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 140)
            if let label {
                Text(verbatim: "\(item.sizeText) · \(label.subtitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140)
            } else {
                Text("\(item.sizeText) · \(item.relativeDateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
