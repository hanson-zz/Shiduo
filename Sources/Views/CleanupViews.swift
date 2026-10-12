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

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    DuplicatesTile()
                        .onTapGesture { store.selection = .duplicates }
                    ForEach(cards) { card in
                        CleanupTile(card: card)
                            .onTapGesture { store.cleanupReview = card.kind }
                    }
                }

                Label("不会直接删除，都进废纸篓，随时可以放回原处。只在 iCloud 云端的文件会被跳过。", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
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
                            Text("\(items.count.formatted()) 个项目")
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
                                    .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                                    .onTapGesture { toggle(item) }
                                    .contextMenu { FileContextMenu(items: [item]) }
                                    .onDrag { NSItemProvider(object: item.url as NSURL) }
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
                Button(selected.count == items.count && !items.isEmpty ? "取消全选" : "全选") {
                    selected = selected.count == items.count ? [] : Set(items.map(\.id))
                }
                .disabled(items.isEmpty)
                Text(selected.isEmpty ? "点缩略图选择要移除的文件" : "已选 \(selected.count) 项 · \(selectedBytes.byteText)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("移除所选") { confirm = selectedItems }
                    .disabled(selected.isEmpty)
                Button {
                    confirm = items
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
        .confirmationDialog(
            "将 \(confirm.count) 个项目移到废纸篓？",
            isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                let list = confirm
                confirm = []
                let moved = store.moveToTrash(list)
                selected.subtract(list.map(\.id))
                if moved > 0 { store.showToast("已把 \(moved) 个项目移到废纸篓") }
            }
            Button("取消", role: .cancel) { confirm = [] }
        } message: {
            Text("随时可以从废纸篓里恢复。只在 iCloud 云端的文件会被跳过。")
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
                ThumbnailView(url: item.url, size: 120)
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
