import AppKit
import SwiftUI

// MARK: - 刘海暂存架：拖文件进来时的三个落点

/// 拖着文件经过刘海暂存架时，内容区换成并排等宽的三个落点：暂存 / 投篮 / 转换。
/// 标准宽度：图标 + 标题 + 一行说明；紧凑宽度：只有图标和两个字。
/// 鼠标下面的那个填强调色、描实线边。放置本身由 NotchShelfDropDelegate 统一处理。
struct NotchDropTargets: View {
    let compact: Bool
    let hovered: NotchShelfController.DropTarget?
    @ObservedObject private var hoop = AirDropHoop.shared
    @ObservedObject private var tools = ShelfTools.shared
    @ObservedObject private var media = MediaTools.shared

    private var iconHeight: CGFloat { compact ? 34 : 38 }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            cell(.shelf)
            cell(.hoop)
            cell(.convert)
        }
    }

    /// 篮筐在投、刚投完时，「投篮」一直亮着（颜色跟着状态走）。
    private var hoopBusy: Bool { hoop.phase != .idle || hoop.flight != nil || hoop.pendingSwish != nil || hoop.stageHold }

    private func lit(_ target: NotchShelfController.DropTarget) -> Bool {
        hovered == target || (target == .hoop && hoopBusy)
    }

    private func accent(_ target: NotchShelfController.DropTarget) -> Color {
        guard target == .hoop else { return Color.accentColor }
        switch hoop.phase {
        case .miss: return HoopPalette.red
        case .done: return HoopPalette.green
        default: return HoopPalette.accent
        }
    }

    private func cell(_ target: NotchShelfController.DropTarget) -> some View {
        let on = lit(target)
        let color = accent(target)
        return VStack(spacing: compact ? 4 : 3) {
            icon(target, on: on)
                .frame(height: iconHeight)
            Text(title(target))
                .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !compact {
                Text(hint(target))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? color.opacity(0.22) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(on ? color : Color.white.opacity(0.22),
                              style: StrokeStyle(lineWidth: on ? 1.5 : 1, dash: on ? [] : [5, 4]))
        )
        .animation(.easeOut(duration: 0.12), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title(target)))
        .accessibilityHint(Text(hint(target)))
    }

    @ViewBuilder
    private func icon(_ target: NotchShelfController.DropTarget, on: Bool) -> some View {
        switch target {
        case .hoop:
            HoopTargetGraphic()
                .frame(width: compact ? 54 : 62)
        case .shelf:
            symbolCircle("tray.and.arrow.down", on: on)
        case .convert:
            if tools.busy || media.busy {
                ProgressView().controlSize(.small)
                    .frame(width: iconHeight, height: iconHeight)
            } else {
                symbolCircle("photo.on.rectangle.angled", on: on)
            }
        }
    }

    private func symbolCircle(_ name: String, on: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: compact ? 14 : 15, weight: .medium))
            .frame(width: iconHeight - 4, height: iconHeight - 4)
            .background(Circle().fill(Color.white.opacity(on ? 0.22 : 0.1)))
    }

    private func title(_ target: NotchShelfController.DropTarget) -> String {
        switch target {
        case .shelf: return String(localized: "暂存")
        case .convert: return String(localized: "转换")
        case .hoop:
            switch hoop.phase {
            case .miss: return String(localized: "没进！")
            case .sending: return String(localized: "正在投送…")
            case .done: return String(localized: "已送达")
            case .idle:
                if let note = hoop.note, !compact { return note }
                return String(localized: "投篮")
            }
        }
    }

    private func hint(_ target: NotchShelfController.DropTarget) -> String {
        switch target {
        case .shelf: return String(localized: "放一下，回头再拖走")
        case .convert: return String(localized: "图片 · 视频 · PDF")
        case .hoop:
            switch hoop.phase {
            case .miss: return String(localized: "再甩一次")
            case .sending: return hoop.fileName
            case .done: return "\(hoop.fileName) · \(hoop.fileSize)"
            case .idle:
                if hoop.isAiming { return String(localized: "松手投篮") }
                return String(localized: "隔空投送")
            }
        }
    }
}

// MARK: - 拖到「转换」以后

/// 拖到「转换」松手后，格式按钮（图片）或处理按钮（视频 / PDF）占满刘海暂存架的内容区。
struct ShelfConvertChooser: View {
    @ObservedObject private var tools = ShelfTools.shared
    @ObservedObject private var media = MediaTools.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .semibold))
                Text(tools.pendingFiles.isEmpty ? String(localized: "\(tools.pendingImages.count) 张图片转为")
                                                : String(localized: "\(tools.pendingFiles.count) 个文件"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    tools.pendingImages = []
                    tools.pendingFiles = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("取消")
                .accessibilityLabel(Text("取消"))
            }
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 5)], spacing: 5) {
                    if !tools.pendingFiles.isEmpty {
                        MediaDropActions(urls: tools.pendingFiles) { tools.pendingFiles = [] }
                            .disabled(media.busy)
                    } else {
                        ForEach(ImageConverter.OutputFormat.available) { format in
                            Button {
                                let images = tools.pendingImages
                                tools.pendingImages = []
                                tools.startConvert(images, to: format)
                            } label: {
                                Text(format.title)
                                    .font(.system(size: 10, weight: .bold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.white.opacity(0.16)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(tools.busy)
                        }
                        MediaDropActions(urls: tools.pendingImages) { tools.pendingImages = [] }
                            .disabled(media.busy)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
