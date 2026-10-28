import SwiftUI

/// 主窗口右下角的「移动到… / 拷贝到…」进度卡片：标题、进度条、「2.1 GB / 5.4 GB · 约 1 分钟 · 当前：xxx」和「取消」。
/// 超过 0.5 秒还没做完、或要跨盘搬数据时才出现（ShelfTransfer.panelVisible）。
/// 玻璃外观和悬停预览一样：macOS 26 液态玻璃，14–15 毛玻璃。
struct MoveProgressCard: View {
    @ObservedObject private var transfer = ShelfTransfer.shared

    var body: some View {
        VStack {
            if transfer.panelVisible, let progress = transfer.progress {
                card(progress)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: transfer.panelVisible)
    }

    private func card(_ progress: MoveOutProgress) -> some View {
        let fraction = MoveProgressLogic.fraction(bytesMode: progress.bytesMode, itemsDone: progress.fileIndex,
                                                  itemCount: progress.fileCount, bytesDone: progress.bytesDone,
                                                  bytesTotal: progress.bytesTotal)
        return TransferProgressCard(
            title: title(progress),
            fraction: fraction,
            detail: { now in detail(progress, fraction: fraction, now: now) },
            isCancelling: transfer.isCancelling,
            cancelHelp: String(localized: "停下还没处理的项目；已经搬好的留在新位置，可以用 ⌘Z 撤销"),
            onCancel: { transfer.cancel() }
        )
    }

    private func title(_ progress: MoveOutProgress) -> String {
        let count = progress.fileCount
        let target = transfer.destinationLabel
        return transfer.isCopy
            ? String(localized: "正在拷贝 \(count) 个项目到「\(target)」")
            : String(localized: "正在移动 \(count) 个项目到「\(target)」")
    }

    private func detail(_ progress: MoveOutProgress, fraction: Double, now: Date) -> String {
        let elapsed = now.timeIntervalSince(transfer.startedAt)
        return MoveProgressLogic.detailText(
            bytesMode: progress.bytesMode, itemsDone: progress.fileIndex, itemCount: progress.fileCount,
            bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal,
            remaining: MoveProgressLogic.remainingSeconds(elapsed: elapsed, fraction: fraction),
            currentName: progress.currentName)
    }
}

/// 进度卡片本身（「移动到… / 拷贝到…」和「备份到硬盘」共用）：标题、进度条、一行说明（每秒重画，剩余时间按时间推算）和「取消」。
struct TransferProgressCard: View {
    let title: String
    let fraction: Double
    let detail: (Date) -> String
    let isCancelling: Bool
    let cancelHelp: String
    let onCancel: () -> Void
    var width: CGFloat = 400
    /// 放在页面里（不是浮在窗口角上）时不要阴影。
    var floating = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(isCancelling ? String(localized: "正在取消…") : String(localized: "取消")) {
                    onCancel()
                }
                .controlSize(.small)
                .disabled(isCancelling)
                .help(cancelHelp)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: width)
        .modifier(HoverGlassBackground(shape: shape))
        .shadow(color: .black.opacity(floating ? 0.12 : 0), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }
}

/// 「备份到硬盘」的进度卡片（主窗口右下角；在「备份到硬盘」页里时页面自己显示，不重复）。
struct BackupProgressCard: View {
    @ObservedObject private var backups = FolderBackupStore.shared
    var floating = true
    var width: CGFloat = 400

    var body: some View {
        VStack {
            if let run = backups.running {
                card(run)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: backups.running != nil)
    }

    private func card(_ run: BackupRunState) -> some View {
        let p = run.progress
        let fraction = MoveProgressLogic.fraction(bytesMode: true, itemsDone: p.filesDone, itemCount: p.fileCount,
                                                  bytesDone: p.bytesDone, bytesTotal: p.bytesTotal)
        return TransferProgressCard(
            title: String(localized: "正在备份 \(p.fileCount) 个文件到「\(run.driveName)」"),
            fraction: fraction,
            detail: { now in
                MoveProgressLogic.detailText(
                    bytesMode: true, itemsDone: p.filesDone, itemCount: p.fileCount,
                    bytesDone: p.bytesDone, bytesTotal: p.bytesTotal,
                    remaining: MoveProgressLogic.remainingSeconds(elapsed: now.timeIntervalSince(run.startedAt), fraction: fraction),
                    currentName: p.currentName)
            },
            isCancelling: run.cancelling,
            cancelHelp: String(localized: "停下还没拷的文件；已经拷好的留在硬盘上，没拷完的那个不会替换掉旧版本"),
            onCancel: { backups.cancel() },
            width: width,
            floating: floating
        )
    }
}
