import AppKit
import SwiftUI

// MARK: - 暂存架小工具（Pro）

/// 暂存架上直接压缩、转换图片格式：新文件放在原文件旁边，并自动放上暂存架。
/// 主窗口的暂存架页面、悬浮暂存架和刘海暂存架共用。原文件一律不动。
@MainActor
final class ShelfTools: ObservableObject {
    static let shared = ShelfTools()

    @Published private(set) var busy = false
    /// 最近一次操作的结果，几秒后自动消失。
    @Published private(set) var message: String?
    /// 刘海暂存架里刚拖进来、等着选格式的图片。
    @Published var pendingImages: [URL] = []
    /// 刘海暂存架里刚拖进来的视频 / PDF，等着选要做的事。
    @Published var pendingFiles: [URL] = []

    /// 拖进来的文件里，除了图片之外还能做点什么（压缩视频、合并 PDF……）。
    static func hasMediaActions(_ urls: [URL]) -> Bool {
        urls.contains(where: MediaToolsLogic.isVideo) || MediaToolsLogic.canMergePDF(urls)
    }

    private var messageToken = 0

    /// 不是 Pro 时打开拾掇 Pro 介绍页（那里有「开始 7 天免费试用」按钮），返回 false。
    /// 不会自动开始试用（暂存架、「更多工具」、图片工具都走这里，行为一致）。
    static func requirePro() -> Bool {
        guard LicenseManager.shared.isPro else {
            NSApp.activate(ignoringOtherApps: true)
            LicenseManager.shared.showPaywall = true
            return false
        }
        return true
    }

    /// 文件拖到「转换」上：放上暂存架；全是图片时给出格式按钮，有视频 / PDF 时给出处理按钮。
    static func handleConvertDrop(_ urls: [URL]) {
        ShelfStore.shared.add(urls)
        let found = Self.images(in: urls)
        if !found.isEmpty, !urls.contains(where: { MediaToolsLogic.isVideo($0) || MediaToolsLogic.isPDF($0) }) {
            shared.pendingFiles = []
            shared.pendingImages = found
        } else if hasMediaActions(urls) {
            shared.pendingImages = []
            shared.pendingFiles = urls
        } else {
            shared.show(String(localized: "没有可以转换的文件"))
        }
    }

    static func images(in urls: [URL]) -> [URL] {
        urls.filter { ImageConverter.canConvert($0) }
    }

    // MARK: 压缩

    func startZip(_ urls: [URL]) {
        guard Self.requirePro() else { return }
        Task { await zip(urls) }
    }

    /// 压缩成 ZIP（多个文件时叫「归档.zip」，重名加编号），放上暂存架。
    @discardableResult
    func zip(_ urls: [URL]) async -> URL? {
        guard !urls.isEmpty else { return nil }
        guard !busy else {
            show(String(localized: "上一个任务还在进行，请稍等"))
            return nil
        }
        busy = true
        let result = await ShelfActions.zip(urls, multipleName: String(localized: "归档"))
        busy = false
        if let result {
            ShelfStore.shared.add([result])
            show(String(localized: "已压缩为 \(result.lastPathComponent)"))
        } else {
            show(String(localized: "没能压缩这些文件。"))
        }
        return result
    }

    // MARK: 转换格式

    func startConvert(_ urls: [URL], to format: ImageConverter.OutputFormat) {
        guard Self.requirePro() else { return }
        Task { await convert(urls, to: format) }
    }

    /// 把图片转成指定格式，放在原图旁边（那里不能写时放进「下载」），新文件放上暂存架。
    @discardableResult
    func convert(_ urls: [URL], to format: ImageConverter.OutputFormat) async -> [URL] {
        let images = Self.images(in: urls)
        guard !busy else {
            show(String(localized: "上一个任务还在进行，请稍等"))
            return []
        }
        let todo = images.filter { !format.matches($0.pathExtension.lowercased()) }
        guard !todo.isEmpty else {
            show(images.isEmpty ? String(localized: "没有可以转换的图片")
                                : String(localized: "已经是 \(format.title) 格式了"))
            return []
        }
        busy = true
        let quality = UserDefaults.standard.object(forKey: "convertQuality") as? Double ?? 0.85
        var out: [URL] = []
        var failed = 0
        for url in todo {
            // 原图旁边；那里不能写时放进「下载」，粘贴来的临时图片放进「图片 / 拾掇」。
            let target = MediaTools.outputFolder(for: url)
            let result = await Task.detached(priority: .userInitiated) {
                ImageConverter.convert(url, to: target, format: format, quality: quality, maxPixel: 0)
            }.value
            if let result { out.append(result) } else { failed += 1 }
        }
        busy = false
        if !out.isEmpty { ShelfStore.shared.add(out) }
        var text = String(localized: "已转换 \(out.count) 张为 \(format.title)，已加入暂存架")
        if failed > 0 { text += String(localized: "，\(failed) 张失败") }
        show(text)
        return out
    }

    // MARK: 提示

    func show(_ text: String) {
        message = text
        messageToken += 1
        let token = messageToken
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.messageToken == token { self.message = nil }
        }
    }
}

// MARK: - 菜单

/// 「转换格式」子菜单：每种能写出的格式一项。
struct ShelfConvertMenu: View {
    let urls: () -> [URL]

    var body: some View {
        Menu("转换格式") {
            ForEach(ImageConverter.OutputFormat.available) { format in
                Button(String(localized: "转换为 \(format.title)")) {
                    ShelfTools.shared.startConvert(urls(), to: format)
                }
            }
        }
    }
}

// MARK: - 「转换格式」格子

/// 拖图片进来就弹出格式按钮；点一下转换暂存架里选中的图片。
/// 刘海暂存架改版后改用 NotchDropTargets 里的「转换」落点 + ShelfConvertChooser，这个格子留给别处复用。
struct ImageConvertDropPane: View {
    let height: CGFloat
    let selected: () -> [URL]
    @ObservedObject private var tools = ShelfTools.shared
    @ObservedObject private var media = MediaTools.shared
    @State private var targeted = false

    var body: some View {
        Group {
            if tools.pendingImages.isEmpty && tools.pendingFiles.isEmpty {
                idle
            } else {
                chooser
            }
        }
        .frame(width: 104)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .help("拖图片、视频或 PDF 到这里转换")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            FileDrop.load(providers) { urls in ShelfTools.handleConvertDrop(urls) }
        }
    }

    private var idle: some View {
        Button {
            let picked = selected()
            let images = ShelfTools.images(in: picked)
            if !images.isEmpty, !picked.contains(where: { MediaToolsLogic.isVideo($0) || MediaToolsLogic.isPDF($0) }) {
                tools.pendingImages = images
            } else if ShelfTools.hasMediaActions(picked) {
                tools.pendingFiles = picked
            } else {
                tools.show(String(localized: "拖图片、视频或 PDF 到这里"))
            }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if tools.busy || media.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(targeted ? 0.22 : 0.1)))
                Text("转换")
                    .font(.caption.weight(.semibold))
                Text(tools.message ?? (targeted ? String(localized: "松手选要做的事") : String(localized: "拖图片、视频或 PDF 到这里")))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if media.busy {
                MediaTaskBar(compact: true)
                    .padding(4)
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(tools.pendingFiles.isEmpty ? String(localized: "\(tools.pendingImages.count) 张图片转为")
                                                : String(localized: "\(tools.pendingFiles.count) 个文件"))
                    .font(.system(size: 10, weight: .semibold))
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
            }
            ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
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
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
    }
}
