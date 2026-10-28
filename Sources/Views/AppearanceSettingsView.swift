import AppKit
import SwiftUI

/// 设置 › 外观：浅色 / 深色、主题色、应用图标（Pro）、文件列表字号、边栏、图标（缩略图、透视文件夹、文件夹图标风格）。
struct AppearanceSettingsSections: View {
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var appearance = AppearanceStore.shared
    @ObservedObject private var iconStatus = AppIconBundleStatus.shared
    @AppStorage(AppAppearance.key) private var mode: AppAppearance = .system
    @AppStorage(FolderWallIconStyle.key) private var folderIconStyle: FolderWallIconStyle = .shiduo

    private var settings: AppearanceSettings { appearance.settings }

    /// 应用图标下面的小字：正常时说明两处都会换；写不进安装包时说明只换了程序坞。
    @ViewBuilder
    private var appIconNote: some View {
        switch iconStatus.state {
        case .ok:
            Text("「应用程序」和程序坞里的图标都会换；退出后程序坞可能要过几秒才刷新")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .writeFailed:
            Label("程序坞已换；「应用程序」里的图标没能改（没有写入权限）", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .clearFailed:
            Label("「应用程序」里的图标没能改回默认（没有写入权限）", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    var body: some View {
        Section("主题") {
            LabeledContent("外观") {
                HStack(spacing: 14) {
                    ForEach(AppAppearance.allCases) { option in
                        AppearanceThumb(mode: option, selected: mode == option) {
                            mode = option
                            option.apply()
                        }
                    }
                }
            }
            LabeledContent("主题色") {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.allCases) { choice in
                            AccentDot(choice: choice, selected: settings.accent == choice) {
                                appearance.update { $0.accent = choice }
                            }
                        }
                    }
                    Text(settings.accent.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("开关、按钮、选中框这些拾掇里的强调色跟着变；「默认」跟随系统设置里的强调色。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            ProHintRow()
            AppIconPicker(selected: settings.appIcon) { id in
                // 点的就是已经选着的那款：设置没变、update 不会触发 apply，这里手动再套一次（程序坞没换过来时点一下能补上）。
                if settings.appIcon == id {
                    AltAppIcons.apply()
                } else {
                    appearance.update { $0.appIcon = id }
                }
            }
            .disabled(!license.isPro)
            appIconNote
        } header: {
            HStack(spacing: 6) {
                Text("应用图标")
                ProBadge()
            }
        }

        Section("文件列表") {
            LabeledContent("字号") {
                HStack(spacing: 10) {
                    Text("\(Int(settings.listFontSize))")
                        .monospacedDigit()
                        .frame(minWidth: 20, alignment: .trailing)
                    Slider(value: appearance.binding(\.listFontSize), in: ListFontSize.range, step: 1)
                        .frame(width: 200)
                    Button("默认") { appearance.update { $0.listFontSize = ListFontSize.defaultSize } }
                        .controlSize(.small)
                        .disabled(settings.listFontSize == ListFontSize.defaultSize)
                }
            }
            Text("列表视图的文字和小图标跟着变大；图标视图里的文件名比它小一号。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("边栏") {
            Toggle("彩色图标", isOn: appearance.binding(\.sidebarColorIcons))
            Picker("图标大小", selection: appearance.binding(\.sidebarIconSize)) {
                Text("小").tag(SidebarIconSize.small)
                Text("中").tag(SidebarIconSize.medium)
                Text("大").tag(SidebarIconSize.large)
            }
            .pickerStyle(.segmented)
        }

        Section("图标") {
            // 以前在 通用 里；键名不变，旧的选择保留。
            Picker("文件夹图标", selection: $folderIconStyle) {
                ForEach(FolderWallIconStyle.allCases) { Text($0.title).tag($0) }
            }
            Text("「拾掇风格」：拾掇里看到的文件夹都是拾掇文件夹，上过色的保留颜色和图案，有自定义图标的把它放在文件夹上。「系统图标」：和访达里一样。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("总是预览图片和视频缩略图", isOn: appearance.binding(\.alwaysPreviewMedia))
            Picker("缩略图起始尺寸", selection: appearance.binding(\.thumbnailStartSize)) {
                Text("不限").tag(ThumbnailStartSize.any)
                Text(verbatim: "32×32").tag(ThumbnailStartSize.p32)
                Text(verbatim: "64×64").tag(ThumbnailStartSize.p64)
                Text(verbatim: "128×128").tag(ThumbnailStartSize.p128)
            }
            Text("图标比这个尺寸小时只显示通用图标，不生成预览图。关掉上面的开关后，图片和视频也按这个尺寸来，并且超过 \(ThumbnailPolicy.bigFolderCount) 项的文件夹一律用通用图标，翻大文件夹更快。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("透视文件夹", isOn: appearance.binding(\.peekFolders))
            Text("文件夹图标上探出里面最新的 3 张图片或视频，找素材一眼就知道是哪个文件夹。只在「拾掇风格」文件夹图标、图标不太小时显示；换装、上过色和有自定义图标的文件夹保持原样。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 跟随系统 / 浅色 / 深色

/// 一张小小的窗口示意图，点了就换。
private struct AppearanceThumb: View {
    let mode: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                preview
                    .frame(width: 76, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    )
                Text(mode.title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            // 左半浅色、右半深色。
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(HStack(spacing: 0) { Color.clear; Color.black })
            }
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let window = dark ? Color(white: 0.17) : Color(white: 0.98)
        let sidebar = dark ? Color(white: 0.24) : Color(white: 0.90)
        let line = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: dark ? [Color(red: 0.16, green: 0.20, blue: 0.42), Color(red: 0.35, green: 0.16, blue: 0.38)]
                                        : [Color(red: 0.62, green: 0.80, blue: 1.0), Color(red: 1.0, green: 0.78, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 2) {
                        Circle().fill(Color.red.opacity(0.85))
                        Circle().fill(Color.yellow.opacity(0.85))
                        Circle().fill(Color.green.opacity(0.85))
                    }
                    .frame(width: 14, height: 4)
                    .padding(.bottom, 2)
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(i == 0 ? Color.accentColor : line).frame(width: i == 0 ? 13 : 11, height: 3)
                    }
                }
                .padding(4)
                .frame(width: 22, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(sidebar)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 9, height: 9)
                        }
                    }
                    Capsule().fill(line).frame(width: 30, height: 3)
                    Capsule().fill(line).frame(width: 22, height: 3)
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(window)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.top, 7)
            .padding(.leading, 8)
            .offset(x: 0, y: 0)
        }
    }
}

// MARK: - 主题色

private struct AccentDot: View {
    let choice: AccentChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if choice == .system {
                    // 默认：灰色圆圈（跟随系统），和彩色圆点区分开。
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                } else {
                    Circle().fill(choice.swatch)
                    Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
                if selected && choice != .system {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? choice.swatch.opacity(0.9) : Color.clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 应用图标

private struct AppIconPicker: View {
    let selected: String?
    let choose: (String?) -> Void
    @Environment(\.isEnabled) private var isEnabled

    /// 28 款一行放不下：可滚动的网格，缩略图下面是名字。
    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 92), spacing: 8, alignment: .top)]

    var body: some View {
        let ids = AltAppIcons.available
        // 存着的是已经删掉的旧款（早先的占位 violet / navy / cobalt）→ 当成默认，选中框落在「默认」上。
        let current = selected.flatMap { ids.contains($0) ? $0 : nil }
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                tile(id: nil, image: AltAppIcons.defaultImage, title: String(localized: "默认"), current: current)
                ForEach(ids, id: \.self) { id in
                    if let image = AltAppIcons.image(for: id) {
                        tile(id: id, image: image, title: AltAppIcons.title(for: id), current: current)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
        }
        .frame(height: 300)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private func tile(id: String?, image: NSImage, title: String, current: String?) -> some View {
        let isSelected = current == id
        return Button {
            choose(id)
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
