import AppKit
import SwiftUI

/// 菜单栏小助手（Pro，设置里打开，默认关闭）：剩余空间、最近下载、快速搜索、打开清理。
struct MenuBarContent: View {
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
                Button {
                    FileActions.reveal([item])
                } label: {
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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
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
