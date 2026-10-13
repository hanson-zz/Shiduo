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

    private var messageToken = 0

    /// 不是 Pro 时打开拾掇 Pro 介绍页，返回 false。
    static func requirePro() -> Bool {
        guard LicenseManager.shared.isPro else {
            NSApp.activate(ignoringOtherApps: true)
            LicenseManager.shared.showPaywall = true
            return false
        }
        return true
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
        guard !urls.isEmpty, !busy else { return nil }
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
        guard !busy else { return [] }
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
            let fm = FileManager.default
            var folder = url.deletingLastPathComponent()
            if !fm.isWritableFile(atPath: folder.path) {
                folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            }
            let target = folder
            let result = await Task.detached(priority: .userInitiated) {
                ImageConverter.convert(url, to: target, format: format, quality: quality, maxPixel: 0)
            }.value
            if let result { out.append(result) } else { failed += 1 }
        }
        busy = false
        if !out.isEmpty { ShelfStore.shared.add(out) }
        var text = String(localized: "已转换 \(out.count) 张为 \(format.title)，已放上暂存架")
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

// MARK: - 刘海暂存架里的「转换格式」格子

/// 拖图片进来就弹出格式按钮；点一下转换暂存架里选中的图片。
struct ImageConvertDropPane: View {
    let height: CGFloat
    let selected: () -> [URL]
    @ObservedObject private var tools = ShelfTools.shared
    @State private var targeted = false

    var body: some View {
        Group {
            if tools.pendingImages.isEmpty {
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
        .help("拖图片到这里转换格式")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            FileDrop.load(providers) { urls in
                ShelfStore.shared.add(urls)
                let images = ShelfTools.images(in: urls)
                if images.isEmpty {
                    ShelfTools.shared.show(String(localized: "没有可以转换的图片"))
                } else {
                    ShelfTools.shared.pendingImages = images
                }
            }
        }
    }

    private var idle: some View {
        Button {
            let images = ShelfTools.images(in: selected())
            if images.isEmpty {
                tools.show(String(localized: "拖图片到这里转换格式"))
            } else {
                tools.pendingImages = images
            }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if tools.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(targeted ? 0.22 : 0.1)))
                Text("转换格式")
                    .font(.caption.weight(.semibold))
                Text(tools.message ?? (targeted ? String(localized: "松手选格式") : String(localized: "拖图片到这里")))
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
    }

    private var chooser: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text("\(tools.pendingImages.count) 张图片转为")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    tools.pendingImages = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("取消")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
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
            }
        }
        .padding(.horizontal, 7)
        .frame(maxHeight: .infinity)
    }
}
