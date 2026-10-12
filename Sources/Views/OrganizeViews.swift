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
        VStack(spacing: 0) {
            if !groups.isEmpty { overview; Divider() }
            split
        }
        .navigationTitle("下载来源")
        .navigationSubtitle("\(groups.count) 个来源 · \(store.items.count) 个文件")
        .onAppear {
            if let id = store.downloadSourceFilter {
                selectedSource = id
                store.downloadSourceFilter = nil
            }
        }
    }

    /// 顶部总览：「N 个文件来自 M 个来源」和一排来源气泡。
    private var overview: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text("记得它从哪儿来")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.accentColor)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(store.items.count)")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("个文件")
                        .font(.title3.weight(.medium))
                }
                Text("来自 \(groups.count) 个来源")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            FlowLayout(spacing: 8) {
                ForEach(groups.sorted { $0.items.count > $1.items.count }.prefix(14)) { group in
                    Button {
                        selectedSource = group.source.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(group.source.tint.color).frame(width: 7, height: 7)
                            Text(group.source.name).fontWeight(.medium)
                            Text("\(group.items.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(selectedSource == group.source.id ? group.source.tint.color.opacity(0.2) : Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var split: some View {
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
