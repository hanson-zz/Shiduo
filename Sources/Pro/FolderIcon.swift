import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 渲染

/// 把系统文件夹图标染成指定颜色，再在正面盖上 SF Symbol / emoji / 图片。
enum FolderIconRenderer {
    /// 渲染成正方形图标。pixels 是像素边长（预览用 256/512，写进访达用 1024）。
    static func render(_ style: FolderIconStyle, pixels: Int = 1024) -> NSImage {
        let side = max(16, pixels)
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        guard let rep = bitmap(side) else { return image }
        let rect = NSRect(x: 0, y: 0, width: side, height: side)

        // 1. 系统文件夹图标画进位图
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSWorkspace.shared.icon(for: .folder).draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // 2. 灰度化后按目标颜色着色，保留原来的明暗
        tint(rep, style.rgb)

        // 3. 叠加层
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        drawOverlay(style, canvas: CGFloat(side))
        NSGraphicsContext.restoreGraphicsState()

        rep.size = image.size
        image.addRepresentation(rep)
        return image
    }

    /// 导出 PNG（1024×1024）。
    static func pngData(_ style: FolderIconStyle, pixels: Int = 1024) -> Data? {
        let image = render(style, pixels: pixels)
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 叠加层用的颜色：同色系、深一点。
    static func overlayColor(_ style: FolderIconStyle) -> NSColor {
        let c = style.rgb
        let base = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        return base.mixed(.black, base.isLight ? 0.45 : 0.32).withAlphaComponent(0.88)
    }

    private static func bitmap(_ side: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)
    }

    /// 每个像素：亮度 / 平均亮度 × 目标颜色。原来的阴影、高光都还在，整体换成目标颜色。
    private static func tint(_ rep: NSBitmapImageRep, _ color: (red: Double, green: Double, blue: Double)) {
        guard let data = rep.bitmapData else { return }
        let count = rep.pixelsWide * rep.pixelsHigh
        let stride = rep.bitsPerPixel / 8
        guard stride >= 4 else { return }

        // 平均亮度（只看比较实的像素）
        var sum = 0.0, n = 0.0
        for i in 0..<count {
            let p = data + i * stride
            let a = Double(p[3])
            guard a > 128 else { continue }
            let l = (0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])) / a
            sum += l
            n += 1
        }
        let average = n > 0 ? max(sum / n, 0.05) : 0.8

        for i in 0..<count {
            let p = data + i * stride
            let a = Double(p[3])
            guard a > 0 else { continue }
            // 位图是预乘 alpha 的，先除掉再算亮度
            let l = (0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])) / a
            let gain = min(l / average, 1.6)
            let r = min(color.red * gain, 1), g = min(color.green * gain, 1), b = min(color.blue * gain, 1)
            p[0] = UInt8(min(255, (r * a).rounded()))
            p[1] = UInt8(min(255, (g * a).rounded()))
            p[2] = UInt8(min(255, (b * a).rounded()))
        }
    }

    /// 叠加层的位置：文件夹正面中心偏下（坐标原点在左下角）。
    static func overlayRect(scale: Double, canvas: CGFloat) -> NSRect {
        let length = canvas * CGFloat(FolderIconStyle.clampScale(scale))
        let center = NSPoint(x: canvas * 0.5, y: canvas * 0.42)
        return NSRect(x: center.x - length / 2, y: center.y - length / 2, width: length, height: length)
    }

    private static func drawOverlay(_ style: FolderIconStyle, canvas: CGFloat) {
        let box = overlayRect(scale: style.overlayScale, canvas: canvas)
        switch style.overlay {
        case .none:
            return
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: box.height * 0.8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [overlayColor(style)]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            symbol.draw(in: fit(symbol.size, in: box), from: .zero, operation: .sourceOver, fraction: 1)
        case .emoji(let text):
            var size = box.height * 0.82
            var attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
            // 字形比字号宽时缩小一点
            let measured = attributed.size()
            if measured.width > box.width, measured.width > 0 {
                size *= box.width / measured.width
                attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
            }
            let s = attributed.size()
            attributed.draw(at: NSPoint(x: box.midX - s.width / 2, y: box.midY - s.height / 2))
        case .image(let path):
            guard let picture = NSImage(contentsOf: URL(fileURLWithPath: path)), picture.size.width > 0, picture.size.height > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: box.width * 0.22, yRadius: box.width * 0.22).addClip()
            // 等比填满（多出来的裁掉）
            let ratio = max(box.width / picture.size.width, box.height / picture.size.height)
            let drawn = NSSize(width: picture.size.width * ratio, height: picture.size.height * ratio)
            picture.draw(in: NSRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func fit(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let ratio = min(box.width / size.width, box.height / size.height)
        let w = size.width * ratio, h = size.height * ratio
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

// MARK: - 服务

/// 一次上色 / 还原的结果。
struct FolderIconOutcome {
    var succeeded: [URL] = []
    var failed: [(url: URL, reason: String)] = []

    /// 失败的中文说明，一行一个。
    var failureText: String {
        failed.map { "\($0.url.lastPathComponent)：\($0.reason)" }.joined(separator: "\n")
    }
}

/// 把图标写进访达里真实的文件夹，记住原样，可以还原。
@MainActor
final class FolderIconService: ObservableObject {
    static let shared = FolderIconService()

    /// 正在编辑的文件夹（非空时弹出编辑器）。
    @Published var editing: [URL] = []
    /// 打开编辑器时的初始颜色（文件夹墙卡片的颜色），nil 用上次的样式。
    @Published var seedColor: String?
    @Published private(set) var ledger = FolderIconLedger()

    private let directory: URL
    private var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shiduo/FolderIcons", isDirectory: true)
        load()
    }

    var history: [FolderIconStyle] { ledger.history }

    func style(for url: URL) -> FolderIconStyle? {
        lookupKey(url).flatMap { ledger.folders[$0]?.style }
    }

    /// 这个文件夹是不是拾掇上的色（只有这样的才给「还原」）。
    func hasRecord(_ url: URL) -> Bool {
        guard !ledger.folders.isEmpty else { return false }
        return lookupKey(url) != nil
    }

    /// 只查不改：路径上的记录 inode 对得上就用它；对不上（同一路径换了个文件夹）或没有，就按 inode 找这个文件夹自己的。
    private func lookupKey(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return ledger.ownerKey(for: path, fileNumber: Self.fileNumber(path), inodeAt: Self.fileNumber)
    }

    /// 把记录对到这个文件夹上（被移走的挪过来，占着路径的别人的记录挪去孤儿位），返回路径。
    private func resolveKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return ledger.claim(path, fileNumber: Self.fileNumber(path), inodeAt: Self.fileNumber)
    }

    nonisolated static func fileNumber(_ path: String) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// 编辑器里的一行提示：上色会在文件夹里放一个隐藏的 Icon 文件。不能改的文件夹不提示（会直接报原因）。
    func syncHint(for urls: [URL]) -> String? {
        var git = false, cloud = false
        for url in urls {
            let path = url.standardizedFileURL.path
            switch FolderIconSyncHint.detect(path: path, home: NSHomeDirectory(), isGitRepo: Self.isInGitRepo(path)) {
            case .git: git = true
            case .cloud: cloud = true
            case nil: break
            }
        }
        if git { return String(localized: "上色会在文件夹里放一个隐藏的 Icon 文件，git 里会多出一个未跟踪的 Icon?，建议在 .gitignore 里加上 Icon?") }
        if cloud { return String(localized: "上色会在文件夹里放一个隐藏的 Icon 文件，同步盘可能把它同步到别的设备，在那边显示成一个空文件或颜色不见") }
        return nil
    }

    /// 文件夹本身或上层（到个人文件夹 / 磁盘根为止）有 .git。
    nonisolated static func isInGitRepo(_ path: String) -> Bool {
        var current = path
        let home = NSHomeDirectory()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: current + "/.git") { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || current == home || parent.isEmpty { return false }
            current = parent
        }
        return false
    }

    // MARK: 入口

    /// 打开编辑器；不是 Pro 就弹付费页（跟「提醒我处理…」一样）。
    func openEditor(_ urls: [URL], color: NSColor? = nil) {
        LicenseManager.shared.startTrialIfNeeded()
        guard LicenseManager.shared.isPro else {
            LicenseManager.shared.showPaywall = true
            return
        }
        seedColor = color.map(FolderPalette.hex)
        editing = urls
    }

    /// 不开编辑器，直接用一个颜色（无叠加层）。不是 Pro 就弹付费页，返回 nil。
    func quickApply(color: NSColor, to urls: [URL]) -> FolderIconOutcome? {
        LicenseManager.shared.startTrialIfNeeded()
        guard LicenseManager.shared.isPro else {
            LicenseManager.shared.showPaywall = true
            return nil
        }
        return apply(FolderIconStyle(color: FolderPalette.hex(color)), to: urls)
    }

    // MARK: 检查

    /// 不能改的文件夹返回中文原因；可以改返回 nil。
    func problem(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return String(localized: "文件夹不存在了")
        }
        guard isDir.boolValue else { return String(localized: "不是文件夹") }
        let values = try? url.resourceValues(forKeys: [.isPackageKey, .volumeIsReadOnlyKey, .volumeIsLocalKey])
        if values?.isPackage == true { return String(localized: "这是应用或文件包，不能换图标") }
        if Self.isProtected(path) { return String(localized: "系统保护的文件夹，为了安全不改它") }
        if values?.volumeIsReadOnly == true { return String(localized: "所在的磁盘是只读的") }
        if values?.volumeIsLocal == false { return String(localized: "网络磁盘上的文件夹暂不支持") }
        if !FileManager.default.isWritableFile(atPath: path) { return String(localized: "没有写入权限") }
        return nil
    }

    /// 系统和用户资源库里的文件夹，以及磁盘根目录、个人文件夹本身，都不碰。
    nonisolated static func isProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if p == "/" || p == home || p == "/Users" || p == "/Volumes" { return true }
        let roots = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/opt", "/cores",
                     home + "/Library", home + "/Applications"]
        return roots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    // MARK: 上色 / 还原

    func apply(_ requested: FolderIconStyle, to urls: [URL]) -> FolderIconOutcome {
        var outcome = FolderIconOutcome()
        // 叠加的图片先拷一份到拾掇自己的目录，原图删了或挪了，历史里的样式还能用
        let style = keepOverlayImage(requested)
        let image = FolderIconRenderer.render(style, pixels: 1024)
        for url in unique(urls) {
            if let reason = problem(for: url) {
                outcome.failed.append((url, reason))
                continue
            }
            let path = resolveKey(url)
            // 第一次上色：先把原样记下来
            var hadCustom = false
            var backup: String?
            if ledger.folders[path] == nil {
                hadCustom = Self.hasCustomIcon(url)
                if hadCustom {
                    backup = backupOriginal(url)
                    // 原来的图标存不下来就不改：不然以后「还原」只能变回系统默认，用户原来的图标就找不回来了
                    guard backup != nil else {
                        outcome.failed.append((url, String(localized: "原来的自定义图标备份不了，为了安全没改")))
                        continue
                    }
                }
            }
            guard NSWorkspace.shared.setIcon(image, forFile: path, options: []) else {
                if let backup { try? FileManager.default.removeItem(at: directory.appendingPathComponent(backup)) }
                outcome.failed.append((url, String(localized: "访达没有接受新图标，可能没有写入权限")))
                continue
            }
            ledger.recordApplied(style, path: path, hadCustomIcon: hadCustom, backupFile: backup, fileNumber: Self.fileNumber(path))
            NSWorkspace.shared.noteFileSystemChanged(path)
            outcome.succeeded.append(url)
        }
        if !outcome.succeeded.isEmpty {
            ledger.remember(style)
            save()
        }
        return outcome
    }

    /// 还原：原来有自定义图标的放回去，没有的清掉自定义图标。
    /// 只动拾掇上过色的文件夹——别的 App 或用户自己设的图标不碰，免得清掉了找不回来。
    func restore(_ urls: [URL]) -> FolderIconOutcome {
        var outcome = FolderIconOutcome()
        var changed = false
        for url in unique(urls) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDir), isDir.boolValue else {
                let gone = url.standardizedFileURL.path
                if let file = ledger.folders[gone]?.backupFile {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
                }
                if ledger.folders.removeValue(forKey: gone) != nil { changed = true }
                outcome.failed.append((url, String(localized: "文件夹不存在了")))
                continue
            }
            let path = resolveKey(url)
            guard let record = ledger.folders[path] else {
                outcome.failed.append((url, String(localized: "这个文件夹的图标不是拾掇改的，不动它")))
                continue
            }
            changed = true
            var original: NSImage?
            if record.hadCustomIcon, let file = record.backupFile {
                original = NSImage(contentsOf: directory.appendingPathComponent(file))
            }
            guard NSWorkspace.shared.setIcon(original, forFile: path, options: []) else {
                outcome.failed.append((url, problem(for: url) ?? String(localized: "访达没有接受改动，可能没有写入权限")))
                continue
            }
            if let file = record.backupFile {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
            ledger.folders[path] = nil
            NSWorkspace.shared.noteFileSystemChanged(path)
            outcome.succeeded.append(url)
        }
        if changed { save() }
        return outcome
    }

    /// 叠加层是图片时，把图片拷进 FolderIcons/Overlays（按内容哈希命名，同一张图只存一份），样式改指向这份拷贝。
    private func keepOverlayImage(_ style: FolderIconStyle) -> FolderIconStyle {
        guard case .image(let path) = style.overlay else { return style }
        let overlays = directory.appendingPathComponent("Overlays", isDirectory: true)
        if path.hasPrefix(overlays.path + "/") { return style }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return style }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let target = overlays.appendingPathComponent(String(hash.prefix(32)) + (ext.isEmpty ? "" : "." + ext))
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.createDirectory(at: overlays, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                return style
            }
        }
        var kept = style
        kept.overlay = .image(target.path)
        return kept
    }

    /// 拾掇移动或重命名了文件夹：记录跟着走。
    func movePath(_ old: String, to new: String) {
        let before = ledger
        ledger.movePath(old, to: new)
        if ledger != before { save() }
    }

    // MARK: 原图标

    /// 文件夹里有 "Icon\r" 文件就说明设过自定义图标。
    nonisolated static func hasCustomIcon(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Icon\r").path)
    }

    /// 把原来的自定义图标存成 icns。文件名每次随机（UUID），不同文件夹的备份不会互相覆盖——
    /// 记录里存着文件名，不靠路径找。失败返回 nil（调用方不会去改这个文件夹）。
    private func backupOriginal(_ url: URL) -> String? {
        guard let icon = (try? url.resourceValues(forKeys: [.customIconKey]))?.customIcon else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = UUID().uuidString
        let name = base + ".icns"
        let target = directory.appendingPathComponent(name)
        if Self.writeICNS(icon, to: target) { return name }
        try? FileManager.default.removeItem(at: target)
        // icns 写不出来就退回 TIFF（同样能还原）
        let tiffName = base + ".tiff"
        if let tiff = icon.tiffRepresentation, (try? tiff.write(to: directory.appendingPathComponent(tiffName))) != nil {
            return tiffName
        }
        return nil
    }

    private nonisolated static func writeICNS(_ image: NSImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 6, nil) else { return false }
        for side in [16, 32, 128, 256, 512, 1024] {
            // icns 只收固定尺寸，先画成正好这么大的位图
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
        }
        return CGImageDestinationFinalize(dest)
    }

    // MARK: 存取

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func load() {
        guard let data = try? Data(contentsOf: ledgerURL),
              let decoded = try? JSONDecoder().decode(FolderIconLedger.self, from: data) else { return }
        ledger = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
        } catch {
            AppLog.files.error("Folder icon ledger save failed: \(AppLog.describe(error), privacy: .public)")
        }
    }
}
