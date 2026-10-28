import AppKit
import Combine
import SwiftUI

/// 清理记录：30 天内拾掇移到废纸篓、搬走的文件，按天分组，可以放回原处。
struct CleanupHistoryView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var history = CleanupHistory.shared
    @State private var selection: Set<UUID> = []
    @State private var working = false
    /// 插拔磁盘、恢复之后刷新一下状态。
    @State private var refreshTick = 0
    /// 每条记录的状态：要 stat 文件（目标是断开的 NAS 时可能卡住），在后台算好存起来，界面只读这个字典。
    @State private var statuses: [UUID: CleanupRecordStatus] = [:]

    private var groups: [CleanupDayGroup] {
        CleanupHistoryLogic.groupByDay(history.records)
    }

    private func status(_ record: CleanupRecord) -> CleanupRecordStatus? {
        record.restoredAt != nil ? .restored : statuses[record.id]
    }

    private var todayRestorable: [CleanupRecord] {
        let today = Calendar.current.startOfDay(for: Date())
        return history.records.filter {
            Calendar.current.startOfDay(for: $0.date) == today && status($0) == .restorable
        }
    }

    private var selectedRestorable: [CleanupRecord] {
        history.records.filter { selection.contains($0.id) && status($0) == .restorable }
    }

    /// 记录或刷新计数变了就重新在后台算一遍状态。
    private var statusKey: [AnyHashable] {
        [refreshTick, history.records.map { "\($0.id)|\($0.currentPath ?? "")|\($0.restoredAt?.timeIntervalSince1970 ?? 0)" }]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if history.records.isEmpty {
                ContentUnavailableView {
                    Label("还没有清理记录", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("用拾掇移到废纸篓或搬走的文件会记在这里，30 天内可以放回原处。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.records) { record in
                                HistoryRow(record: record, status: status(record), restore: { restore([record]) })
                                    .tag(record.id)
                                    .stableContextMenu { rowMenu(record) }
                            }
                        }
                    }
                }
                .id(refreshTick)
                .scrollContentBackground(.hidden)
            }
            Divider()
            footer
        }
        .navigationTitle("清理记录")
        .onAppear { history.load() }
        .task(id: statusKey) {
            let records = history.records
            let fresh = await CleanupHistory.statuses(of: records)
            if !Task.isCancelled { statuses = fresh }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshTick += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshTick += 1 }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("清理记录")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("拾掇移到废纸篓或搬走的文件，30 天内都能放回原处")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("恢复所选（\(selectedRestorable.count)）") { restore(selectedRestorable) }
                .disabled(selectedRestorable.isEmpty || working)
            Button {
                restore(todayRestorable)
            } label: {
                Label("全部恢复今天的", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)
            .disabled(todayRestorable.isEmpty || working)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("如果你清空了废纸篓，文件就无法恢复了。记录只保留 30 天。")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rowMenu(_ record: CleanupRecord) -> some View {
        if status(record) == .restorable {
            Button("恢复") { restore([record]) }
        }
        if let current = record.currentPath, status(record) == .restorable || status(record) == .restored {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current)]) }
        }
        Button("拷贝原路径") { FileActions.copy(record.originalPath) }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "今天") }
        if calendar.isDateInYesterday(day) { return String(localized: "昨天") }
        return day.formatted(date: .complete, time: .omitted)
    }

    private func restore(_ records: [CleanupRecord]) {
        guard !records.isEmpty, !working else { return }
        working = true
        Task {
            await store.restore(records)
            selection.subtract(records.map(\.id))
            working = false
            refreshTick += 1
        }
    }
}

private struct HistoryRow: View {
    let record: CleanupRecord
    /// 还没在后台算好时为 nil。
    let status: CleanupRecordStatus?
    let restore: () -> Void

    private var actionText: String {
        switch record.action {
        case .trash: return String(localized: "移到废纸篓")
        case .moveOut: return String(localized: "搬到 \(record.destinationName ?? "")")
        }
    }

    private var statusText: String {
        guard let status else { return String(localized: "正在检查…") }
        switch status {
        case .restorable: return String(localized: "可恢复")
        case .restored: return String(localized: "已恢复")
        case .trashEmptied: return String(localized: "废纸篓已清空")
        case .destinationOffline: return String(localized: "目标盘未连接")
        case .missing: return String(localized: "文件已不在")
        }
    }

    private var statusColor: Color {
        guard let status else { return .secondary }
        switch status {
        case .restorable: return .green
        case .restored: return .blue
        case .trashEmptied, .missing: return .secondary
        case .destinationOffline: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 图标只在确认文件还在时按文件取（状态在后台算好），不在每次重绘时 stat。
            Image(nsImage: NSWorkspace.shared.icon(forFile: (status == .restorable || status == .restored ? record.currentPath : nil) ?? "/System/Library/CoreServices/Finder.app"))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(record.size > 0 ? record.size.byteText : "--")
                    Text(verbatim: "·")
                    Text(actionText)
                    Text(verbatim: "·")
                    Text((record.originalFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .help(record.originalPath)
            Spacer()
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusColor.opacity(0.12)))
            Text(record.date.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("恢复", action: restore)
                .disabled(status != .restorable)
        }
        .padding(.vertical, 3)
    }
}
