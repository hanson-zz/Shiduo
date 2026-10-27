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
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let fraction = MoveProgressLogic.fraction(bytesMode: progress.bytesMode, itemsDone: progress.fileIndex,
                                                  itemCount: progress.fileCount, bytesDone: progress.bytesDone,
                                                  bytesTotal: progress.bytesTotal)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title(progress))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            HStack(spacing: 10) {
                // 剩余时间按时间推算：每秒重画一次文字（进度本身另外限流更新）。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(detail(progress, fraction: fraction, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button(transfer.isCancelling ? String(localized: "正在取消…") : String(localized: "取消")) {
                    transfer.cancel()
                }
                .controlSize(.small)
                .disabled(transfer.isCancelling)
                .help("停下还没处理的项目；已经搬好的留在新位置，可以用 ⌘Z 撤销")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 400)
        .modifier(HoverGlassBackground(shape: shape))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
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
