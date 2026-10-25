import SwiftUI

/// 首页问候语下方的「今天新增 N 个 ›」小标签，点开是今天进来的文件。
struct TodayAddedChip: View {
    @EnvironmentObject private var store: LibraryStore
    /// 演示模式 --page=today 截图时直接打开弹窗。
    @State private var showing = Demo.isOn && Demo.page == "today"

    var body: some View {
        let count = store.todayAdded.count
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                Text("今天新增 \(count) 个")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("看看今天新进来的文件")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            TodayAddedPopover(close: { showing = false })
                .environmentObject(store)
        }
    }
}

/// 「今天新增」弹窗：按类型筛选，最多列 5 个，双击打开、可以拖出去、右键菜单和列表里一样。
struct TodayAddedPopover: View {
    @EnvironmentObject private var store: LibraryStore
    var close: () -> Void
    @State private var kind: TodayKind?
    @State private var hovered: String?

    private static let shown = 5

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        let all = store.todayAdded
        let summary = TodayAddedLogic.summary(all)
        let kinds = summary.kinds
        // 选中的类型已经没有文件了（刚删掉 / 搬走）：回到「全部」。
        let current = kinds.contains(where: { $0.kind == kind }) ? kind : nil
        let list = TodayAddedLogic.items(all, of: current)
        let home = NSHomeDirectory()

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今天新增")
                    .font(.headline)
                Spacer()
                Text("\(summary.count) 个 · \(summary.bytes.byteText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if all.isEmpty {
                Text("今天还没有新文件")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(String(localized: "全部 \(summary.count)"), selected: current == nil) { kind = nil }
                        ForEach(kinds) { entry in
                            filterChip("\(entry.kind.title) \(entry.count)", selected: current == entry.kind) { kind = entry.kind }
                        }
                    }
                }

                VStack(spacing: 2) {
                    ForEach(Array(list.prefix(Self.shown))) { item in
                        row(item, home: home)
                    }
                }

                Divider()

                HStack {
                    let rest = list.count - Self.shown
                    if rest > 0 {
                        Text("还有 \(rest) 个")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        close()
                        store.showAddedToday(kind: current)
                    } label: {
                        HStack(spacing: 3) {
                            Text("全部显示")
                            Image(systemName: "arrow.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: FileItem, home: String) -> some View {
        HStack(spacing: 10) {
            ThumbnailView(url: item.url, size: 36, fill: true, modified: item.modified, isFolder: item.isPlainFolder)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(TodayAddedLogic.location(of: item.path, home: home).title) · \(item.sizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let added = item.added {
                Text(verbatim: Self.timeFormatter.string(from: added))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered == item.id ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .onTapGesture(count: 2) {
            close()
            store.openItems([item])
        }
        .contextMenu { FileContextMenu(items: [item]) }
        .onDrag { InAppDrag.copyOnlyProvider(item.url) }
        .help(item.path)
    }
}
