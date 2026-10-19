import AppKit
import SwiftUI

/// 菜单栏小助手（Pro，设置里打开，默认关闭）：剩余空间、最近下载、快速搜索、打开清理。
struct MenuBarContent: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var recent: [FileItem] = []
    @State private var free: Int64 = 0
    @State private var total: Int64 = 0
    @State private var diskName = String(localized: "启动磁盘")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("拾掇")
                    .font(.headline)
                ProBadge()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(diskName) 可用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(free > 0 ? free.byteText : "--")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                if total > 0 {
                    ProgressView(value: Double(total - free), total: Double(total))
                        .tint(free < total / 10 ? .orange : .accentColor)
                }
            }

            ReclaimableRow(cleanup: store.cleanup, duplicates: store.duplicates)

            Divider()

            Text("最近下载")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if recent.isEmpty {
                Text("没有最近下载的文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(recent) { item in
                RecentDownloadRow(item: item)
                    .contextMenu {
                        Button("在访达中显示") { FileActions.reveal([item]) }
                        Button("加入暂存架") { store.addToShelf([item]) }
                        Divider()
                        // 和主窗口同一套：清理记录、⌘Z 撤销、音效。
                        Button("移到废纸篓") {
                            store.moveToTrash([item]) { moved in
                                recent.removeAll { moved.contains($0.path) }
                            }
                        }
                    }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    QuickSearchController.shared.show()
                } label: {
                    Label("快速搜索", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    CleanupReminder.shared.openCleanup()
                } label: {
                    Label("打开清理", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(width: 300)
        .task { await refresh() }
    }

    private func refresh() async {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey,
        ]
        if let values = try? root.resourceValues(forKeys: keys) {
            free = values.volumeAvailableCapacityForImportantUsage ?? 0
            total = Int64(values.volumeTotalCapacity ?? 0)
            if let name = values.volumeLocalizedName, !name.isEmpty { diskName = name }
        }
        if Demo.isOn { return }
        let items = await Queries.recentDownloads(limit: 5)
        recent = items
    }
}

/// 菜单里的一条最近下载：点一下在访达中显示，按住可以直接拖进邮件、微信、Slack、Figma 等 App。
private struct RecentDownloadRow: View {
    let item: FileItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ThumbnailView(url: item.url, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.sizeText) · \(item.relativeDateText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hovering {
                Image(systemName: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        // 点按和拖出交给 AppKit：拖出去的是文件本身（拷贝），原文件留在“下载”里。
        .overlay(FileCellMouseArea(
            urls: { [item.url] },
            onClick: { _, _ in FileActions.reveal([item]) }
        ))
        .onHover { hovering = $0 }
        .help("点按在访达中显示，按住拖进其他 App")
    }
}

/// 清理建议和重复文件加起来可以腾出的空间（和首页、清理页用的是同一份扫描结果）。
enum Reclaimable {
    @MainActor
    static func bytes(cleanup: CleanupScanner, duplicates: DuplicateScanner) -> Int64 {
        cleanup.totalBytes + duplicates.reclaimable
    }
}

/// 菜单里的「可腾出 X GB」，点一下打开清理页。为 0 时不显示。
private struct ReclaimableRow: View {
    @ObservedObject var cleanup: CleanupScanner
    @ObservedObject var duplicates: DuplicateScanner

    var body: some View {
        let bytes = Reclaimable.bytes(cleanup: cleanup, duplicates: duplicates)
        if bytes > 0 {
            Button {
                CleanupReminder.shared.openCleanup()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text("可腾出 \(bytes.byteText)")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开清理")
        }
    }
}

/// 菜单栏图标；打开开关时在旁边显示可腾出的空间（例如「5.3 GB」），为 0 时只显示图标。
struct MenuBarLabel: View {
    nonisolated static let showReclaimableKey = "menuBarShowsReclaimable"

    @ObservedObject var cleanup: CleanupScanner
    @ObservedObject var duplicates: DuplicateScanner
    @AppStorage(MenuBarLabel.showReclaimableKey) private var showReclaimable = true

    var body: some View {
        let bytes = Reclaimable.bytes(cleanup: cleanup, duplicates: duplicates)
        if showReclaimable && bytes > 0 {
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                Text(bytes.byteText)
            }
            .accessibilityLabel(Text("拾掇：可腾出 \(bytes.byteText)"))
        } else {
            Image(systemName: "tray.full")
                .accessibilityLabel(Text("拾掇"))
        }
    }
}
