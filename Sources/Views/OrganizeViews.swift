import SwiftUI

// MARK: - 下载来源

struct DownloadSourcesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedSource: String? = "__all__"

    private var groups: [SourceGroup] { SourceGroup.make(from: store.items) }

    private var visible: [FileItem] {
        guard let id = selectedSource, id != "__all__" else { return store.items }
        return store.items.filter { $0.downloadSource?.id == id }
    }

    private var knownGroups: [SourceGroup] { groups.filter { !$0.source.id.hasPrefix("site:") } }
    private var siteGroups: [SourceGroup] { groups.filter { $0.source.id.hasPrefix("site:") } }

    var body: some View {
        HSplitView {
            List(selection: $selectedSource) {
                Label("全部来源（\(store.items.count)）", systemImage: "tray.full")
                    .tag("__all__")
                if !knownGroups.isEmpty {
                    Section("应用和服务") {
                        ForEach(knownGroups) { row($0) }
                    }
                }
                if !siteGroups.isEmpty {
                    Section("其他网站") {
                        ForEach(siteGroups) { row($0) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minWidth: 210, idealWidth: 250, maxWidth: 320, maxHeight: .infinity)

            Group {
                if store.isLoading && store.items.isEmpty {
                    ProgressView("正在读取下载记录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visible.isEmpty {
                    ContentUnavailableView(
                        "没有下载来源记录",
                        systemImage: "globe",
                        description: Text("从浏览器、邮箱、网盘下载的文件会记下来源，这里按来源分组显示。")
                    )
                } else {
                    FileCollectionView(items: visible)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("下载来源")
        .navigationSubtitle("\(groups.count) 个来源 · \(store.items.count) 个文件")
        .onAppear {
            if let id = store.downloadSourceFilter {
                selectedSource = id
                store.downloadSourceFilter = nil
            }
        }
    }

    private func row(_ group: SourceGroup) -> some View {
        HStack(spacing: 10) {
            TintedIcon(symbol: group.source.symbol, tint: group.source.tint.color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.source.name)
                    .lineLimit(1)
                Text("\(group.items.count) 个 · \(group.bytes.byteText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(group.source.id)
    }
}

// MARK: - 分组审阅（重复文件、相似照片、清理卡片共用）

struct GroupReviewView: View {
    @EnvironmentObject private var store: LibraryStore
    let groups: [FileGroup]
    /// 每组至少保留一份（重复文件、相似照片）。
    var keepOne = true
    /// 打开时默认全选（清理卡片）。
    var preselectAll = false

    @State private var marked: Set<String> = []
    @State private var confirming = false

    private var allItems: [FileItem] { groups.flatMap(\.items) }

    private var markedItems: [FileItem] { allItems.filter { marked.contains($0.id) } }

    private var markedBytes: Int64 { markedItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            if keepOne {
                                Button("只保留最新的一份") { keepNewest(group) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if keepOne {
                    Button("自动选择") { autoMark() }
                        .help("每组保留最新的一份，其余全部选中")
                } else {
                    Button("全选") { marked = Set(allItems.map(\.id)) }
                }
                Button("清除选择") { marked = [] }
                    .disabled(marked.isEmpty)
                Spacer()
                Text("已选 \(marked.count) 项，共 \(markedBytes.byteText)")
                    .foregroundStyle(.secondary)
                Button("移到废纸篓", role: .destructive) { confirming = true }
                    .disabled(marked.isEmpty)
            }
            .padding(12)
        }
        .onAppear { if preselectAll { marked = Set(allItems.map(\.id)) } }
        .confirmationDialog(
            "将 \(marked.count) 个项目移到废纸篓？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { trash() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(keepOne ? "每组至少会保留一份。随时可以从废纸篓里恢复。" : "随时可以从废纸篓里恢复。只在 iCloud 云端的文件会被跳过。")
        }
    }

    private func row(_ item: FileItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { marked.contains(item.id) },
                set: { on in
                    if on { marked.insert(item.id) } else { marked.remove(item.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            ThumbnailView(url: item.url, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.sizeText)
                Text(item.sortDate == .distantPast ? "--" : item.sortDate.shortText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu { FileContextMenu(items: [item]) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(item.path)
    }

    private func newest(_ group: FileGroup) -> FileItem? {
        group.items.max { $0.sortDate < $1.sortDate }
    }

    private func keepNewest(_ group: FileGroup) {
        let keep = newest(group)?.id
        for item in group.items {
            if item.id == keep { marked.remove(item.id) } else { marked.insert(item.id) }
        }
    }

    private func autoMark() {
        marked = []
        for group in groups { keepNewest(group) }
    }

    private func trash() {
        var targets = marked
        if keepOne {
            for group in groups where group.items.allSatisfy({ targets.contains($0.id) }) {
                if let keep = newest(group) { targets.remove(keep.id) }
            }
        }
        let list = allItems.filter { targets.contains($0.id) }
        store.moveToTrash(list)
        marked.subtract(targets)
    }
}

// MARK: - 重复文件

struct DuplicatesView: View {
    @EnvironmentObject private var scanner: DuplicateScanner

    var body: some View {
        VStack(spacing: 0) {
            ScanHeader(
                title: "重复文件",
                detail: "比较 1 MB 以上文件的大小和 SHA-256 指纹，只有内容完全相同才算重复。",
                isRunning: scanner.isRunning,
                progress: scanner.progress,
                status: scanner.status,
                hasScanned: scanner.hasScanned,
                start: { scanner.start() },
                cancel: { scanner.cancel() }
            ) {
                EmptyView()
            }
            Divider()
            if scanner.groups.isEmpty {
                ContentUnavailableView(
                    scanner.hasScanned ? "没有发现重复文件" : "还没有扫描",
                    systemImage: "doc.on.doc",
                    description: Text(scanner.hasScanned ? "你的文件很整齐。" : "点“开始扫描”，在本机查找内容完全相同的文件。")
                )
            } else {
                GroupReviewView(groups: scanner.groups, keepOne: true)
            }
        }
        .navigationTitle("重复文件")
        .navigationSubtitle(scanner.groups.isEmpty ? "" : "可释放 \(scanner.reclaimable.byteText)")
    }
}

// MARK: - 相似照片

struct SimilarPhotosView: View {
    @EnvironmentObject private var scanner: SimilarPhotoScanner

    var body: some View {
        VStack(spacing: 0) {
            ScanHeader(
                title: "相似照片",
                detail: "用 Vision 在本机比较最近 800 张图片的画面特征，找出连拍、重复截图等看起来差不多的照片。",
                isRunning: scanner.isRunning,
                progress: scanner.progress,
                status: scanner.status,
                hasScanned: scanner.hasScanned,
                start: { scanner.start() },
                cancel: { scanner.cancel() }
            ) {
                HStack(spacing: 6) {
                    Text("严格")
                        .font(.caption)
                    Slider(value: $scanner.threshold, in: 0.2...0.8)
                        .frame(width: 120)
                    Text("宽松")
                        .font(.caption)
                }
                .disabled(scanner.isRunning)
                .help("调整后重新扫描生效")
            }
            Divider()
            if scanner.groups.isEmpty {
                ContentUnavailableView(
                    scanner.hasScanned ? "没有发现相似的照片" : "还没有扫描",
                    systemImage: "photo.stack",
                    description: Text(scanner.hasScanned ? "可以把右上角的滑块调宽松一点再试。" : "点“开始扫描”，在本机查找相似的照片。")
                )
            } else {
                GroupReviewView(groups: scanner.groups, keepOne: true)
            }
        }
        .navigationTitle("相似照片")
    }
}

struct ScanHeader<Extra: View>: View {
    let title: String
    let detail: String
    let isRunning: Bool
    let progress: Double
    let status: String
    let hasScanned: Bool
    let start: () -> Void
    let cancel: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail)
                    .foregroundStyle(.secondary)
                if isRunning {
                    HStack {
                        ProgressView(value: progress)
                            .frame(maxWidth: 260)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            extra()
            if isRunning {
                Button("停止", action: cancel)
            } else {
                Button(hasScanned ? "重新扫描" : "开始扫描", action: start)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

// MARK: - 清理建议

struct CleanupView: View {
    @EnvironmentObject private var scanner: CleanupScanner
    @State private var openCard: CleanupKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("清理建议")
                            .font(.largeTitle.bold())
                        Text(scanner.hasScanned
                             ? "大约可以腾出 \(scanner.totalBytes.byteText)。所有操作都只是移到废纸篓，只在 iCloud 云端的文件不会动。"
                             : "拾掇会找出一些通常可以放心清理的文件，由你逐个确认。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if scanner.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(scanner.hasScanned ? "重新扫描" : "开始扫描") {
                            Task { await scanner.scan() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(scanner.cards) { card in
                        CleanupCardView(card: card)
                            .onTapGesture { if !card.items.isEmpty { openCard = card.kind } }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("清理建议")
        .task {
            if !scanner.hasScanned && !scanner.isRunning { await scanner.scan() }
        }
        .sheet(item: $openCard) { kind in
            CleanupReviewSheet(kind: kind)
        }
    }
}

struct CleanupCardView: View {
    let card: CleanupCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: card.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text(card.bytes.byteText)
                    .font(.title3.weight(.semibold))
            }
            Text(card.kind.title)
                .font(.headline)
            Text(card.kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.items.isEmpty ? "没有需要清理的" : "\(card.items.count) 个项目 · 点按查看")
                .font(.caption)
                .foregroundStyle(card.items.isEmpty ? Color.secondary : Color.accentColor)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .opacity(card.items.isEmpty ? 0.6 : 1)
    }
}

struct CleanupReviewSheet: View {
    @EnvironmentObject private var scanner: CleanupScanner
    @Environment(\.dismiss) private var dismiss
    let kind: CleanupKind

    private var card: CleanupCard? { scanner.cards.first { $0.kind == kind } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.title2.bold())
                    Text(kind.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if let card, !card.items.isEmpty {
                GroupReviewView(
                    groups: [FileGroup(id: kind.rawValue, title: "\(card.items.count) 个项目 · \(card.bytes.byteText)", items: card.items)],
                    keepOne: false,
                    preselectAll: true
                )
            } else {
                ContentUnavailableView("已经清理完了", systemImage: "checkmark.circle")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
