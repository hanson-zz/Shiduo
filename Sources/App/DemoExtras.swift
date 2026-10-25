import AppKit
import Foundation

/// 演示模式（--demo）里 v0.14 新页面要用的示例数据：清理记录、搬家目标、卸载 App、图片工具等。
/// 只在 --demo 启动时用到，示例文件都放在临时目录里，不碰用户文件。
extension Demo {
    /// 截图时先点「开始 7 天免费试用」（--pro），Pro 页面才是解锁后的样子。走的是正常的试用流程。
    static let wantsPro = ProcessInfo.processInfo.arguments.contains("--pro")

    /// 示例「下载」文件夹（整理下载预览用）。
    static var downloadsFolder: URL { folder.appendingPathComponent(n("下载"), isDirectory: true) }

    /// 放清理记录、搬家目标的临时目录（不放在 Demo.folder 里，免得出现在空间占用图上）。
    static let extraFolder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(english ? "ShiduoDemoExtra-en" : "ShiduoDemoExtra", isDirectory: true)

    /// 卸载 App 演示用的「个人文件夹」：里面有一个示例 App 和它留在 Library 里的文件。
    static let uninstallHome: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShiduoDemoHome", isDirectory: true)

    /// 示例个人文件夹里的路径显示成 ~/…。
    static func tildePath(_ path: String) -> String {
        let home = uninstallHome.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: 搬家目标

    private static var t7: URL { extraFolder.appendingPathComponent("T7", isDirectory: true) }
    private static var nas: URL { extraFolder.appendingPathComponent("NAS", isDirectory: true) }
    private static var cloud: URL { extraFolder.appendingPathComponent("iCloud", isDirectory: true) }

    static func moveDestinations() -> [MoveDestination] {
        for url in [t7, nas, cloud] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return [
            MoveDestination(kind: .external, name: english ? "Samsung T7" : "移动硬盘 T7", path: t7.path),
            MoveDestination(kind: .network, name: "NAS", path: nas.path),
            MoveDestination(kind: .iCloud, name: english ? "iCloud Drive" : "iCloud 云盘", path: cloud.path),
        ]
    }

    static func fakeFreeBytes(_ path: String) -> Int64? {
        switch path {
        case t7.path: return 812_000_000_000
        case nas.path: return 3_420_000_000_000
        case cloud.path: return 146_000_000_000
        default: return nil
        }
    }

    // MARK: 清理记录

    static func cleanupRecords() -> [CleanupRecord] {
        let fm = FileManager.default
        let trash = extraFolder.appendingPathComponent("Trash", isDirectory: true)
        let movedDir = t7.appendingPathComponent(english ? "Shiduo Move Out" : "拾掇搬家", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try? fm.createDirectory(at: movedDir, withIntermediateDirectories: true)
        let home = NSHomeDirectory()
        let now = Date()
        let today = UUID(), today2 = UUID(), yesterday = UUID(), older = UUID()
        func file(_ dir: URL, _ name: String) -> String {
            let url = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: Data("demo".utf8)) }
            return url.path
        }
        func rec(_ batch: UUID, _ hours: Double, _ action: CleanupRecord.Action, _ name: String, _ folder: String,
                 _ size: Int64, current: String?, restored: Bool = false) -> CleanupRecord {
            var r = CleanupRecord(batchID: batch, date: now.addingTimeInterval(-hours * 3600), action: action, name: name,
                                  originalPath: home + "/" + folder + "/" + name, currentPath: current, size: size)
            if action == .moveOut {
                r.destinationName = english ? "Samsung T7" : "移动硬盘 T7"
                r.destinationRoot = t7.path
                r.aliasPath = r.originalPath
            }
            if restored { r.restoredAt = now.addingTimeInterval(-(hours - 0.5) * 3600) }
            return r
        }
        let vlog = n("旅行 Vlog.mov"), grad = n("毕业典礼.mp4"), backup = n("照片备份.zip")
        return [
            rec(today, 0.4, .trash, "WeChatMac.dmg", "Downloads", 498_000_000, current: file(trash, "WeChatMac.dmg")),
            rec(today, 0.4, .trash, "Figma.dmg", "Downloads", 312_000_000, current: file(trash, "Figma.dmg")),
            rec(today, 0.4, .trash, "Python-3.13.pkg", "Downloads", 71_000_000, current: file(trash, "Python-3.13.pkg")),
            rec(today2, 1.2, .moveOut, vlog, "Movies", 1_820_000_000, current: file(movedDir, vlog)),
            rec(today2, 1.2, .moveOut, grad, "Movies", 980_000_000, current: file(movedDir, grad)),
            rec(yesterday, 26, .trash, n("截屏 2026-07-21 下午8.30.png"), "Desktop", 1_050_000, current: nil, restored: true),
            rec(yesterday, 26, .trash, n("截屏 2026-08-02 上午11.05.png"), "Desktop", 1_300_000,
                current: file(trash, n("截屏 2026-08-02 上午11.05.png"))),
            rec(older, 74, .moveOut, backup, "Downloads", 1_200_000_000, current: file(movedDir, backup)),
            rec(older, 74, .trash, n("海报 (1).png"), "Desktop", 2_200_000, current: nil),
        ]
    }

    // MARK: 卸载 App

    /// 一个示例 App（名字是虚构的）和它留在示例个人文件夹 Library 里的偏好、缓存、数据。
    static func makeUninstallApp() -> URL {
        let fm = FileManager.default
        let id = "com.example.pixelnote"
        let name = "PixelNote"
        let app = uninstallHome.appendingPathComponent("Applications/\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try? fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL", "CFBundleExecutable": name, "CFBundleShortVersionString": "3.2",
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        writeBytes(contents.appendingPathComponent("MacOS/\(name)"), 96_000_000)
        if !FolderIconService.hasCustomIcon(app) {
            NSWorkspace.shared.setIcon(appIcon(), forFile: app.path, options: [])
        }
        let lib = uninstallHome.appendingPathComponent("Library", isDirectory: true)
        let leftovers: [(String, Int64)] = [
            ("Application Support/\(name)/Library.db", 148_000_000),
            ("Caches/\(id)/Cache.db", 212_000_000),
            ("Containers/\(id)/Data/state.plist", 6_400_000),
            ("Preferences/\(id).plist", 12_000),
            ("Application Scripts/\(id)/helper.scpt", 4_000),
        ]
        for (path, size) in leftovers {
            let url = lib.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writeBytes(url, size)
        }
        return app
    }

    /// 写真的字节（不是稀疏文件），这样占用空间算出来和示例里写的大小一致。
    private static func writeBytes(_ url: URL, _ size: Int64) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path), (attrs[.size] as? Int64) == size { return }
        fm.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let chunk = Data(repeating: 0x5A, count: 4_000_000)
        var left = size
        while left > 0 {
            let n = Int(min(Int64(chunk.count), left))
            handle.write(n == chunk.count ? chunk : chunk.prefix(n))
            left -= Int64(n)
        }
        try? handle.close()
    }

    private static func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let body = rect.insetBy(dx: 50, dy: 50)
            let path = NSBezierPath(roundedRect: body, xRadius: 92, yRadius: 92)
            NSGradient(colors: [.systemOrange, .systemPink])?.draw(in: path, angle: -60)
            if let symbol = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 210, weight: .semibold)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let s = tinted.size
                tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    // MARK: 图片工具

    /// 图片工具各个标签页用的示例图（已经在示例文件里）。
    static func studioImages(for mode: ImageStudio.Mode) -> [URL] {
        let all = folder
        func url(_ dir: String, _ name: String) -> URL { all.appendingPathComponent(n(dir)).appendingPathComponent(n(name)) }
        switch mode {
        case .stitch:
            return [url("图片", "西湖日落.jpg"), url("图片", "猫咪午睡.jpg"), url("图片", "海边.jpg"), url("图片", "生日蛋糕.jpg"),
                    url("下载", "海报.png"), url("下载", "AI 插画.png")]
        case .beautify, .annotate:
            return [url("桌面", "截屏 2026-10-11 上午9.41.png")]
        case .cutout:
            return [cutoutSample()]
        case .upscale:
            return [url("下载", "AI 插画.png")]
        }
    }

    /// 抠图示例：浅色背景上一个清楚的主体（一只杯子），本机 Vision 能认出前景。
    private static func cutoutSample() -> URL {
        let url = folder.appendingPathComponent(n("图片")).appendingPathComponent(english ? "Mug.png" : "马克杯.png")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let image = NSImage(size: NSSize(width: 1200, height: 900), flipped: false) { rect in
            NSGradient(colors: [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.84, alpha: 1)])?.draw(in: rect, angle: -90)
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: 380, y: 150, width: 440, height: 70)).fill()
            let mug = NSBezierPath(roundedRect: NSRect(x: 420, y: 190, width: 330, height: 400), xRadius: 40, yRadius: 40)
            NSGradient(colors: [.systemTeal, .systemBlue])?.draw(in: mug, angle: 0)
            let handle = NSBezierPath(ovalIn: NSRect(x: 690, y: 290, width: 170, height: 200))
            handle.lineWidth = 42
            NSColor.systemBlue.setStroke()
            handle.stroke()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 470, y: 320, width: 40, height: 210), xRadius: 20, yRadius: 20).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        return url
    }
}
