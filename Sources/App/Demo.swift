import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 演示模式：用一批生成出来的示例文件填满界面，用来给 README 截图。
///
///     Shiduo.app/Contents/MacOS/Shiduo --demo --page=home [--dark]
///
/// 不读 Spotlight，不碰用户文件；示例文件放在临时目录里。
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("--demo")
    static let isDark = ProcessInfo.processInfo.arguments.contains("--dark")

    static var page: String {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--page=") }
            .map { String($0.dropFirst("--page=".count)) } ?? "home"
    }

    static let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ShiduoDemo", isDirectory: true)

    // MARK: - 示例文件

    struct Spec {
        let name: String
        let kind: Kind
        let size: Int64
        let daysAgo: Double
        var from: [String] = []
        var screenshot = false
    }

    enum Kind { case image, video, music, pdf, doc, archive, installer }

    private static let palettes: [[NSColor]] = [
        [.systemPink, .systemOrange], [.systemTeal, .systemBlue], [.systemPurple, .systemIndigo],
        [.systemGreen, .systemTeal], [.systemYellow, .systemOrange], [.systemBlue, .systemPurple],
        [.systemRed, .systemPink], [.systemMint, .systemCyan],
    ]

    static let specs: [Spec] = [
        Spec(name: "西湖日落.jpg", kind: .image, size: 4_820_000, daysAgo: 0.2),
        Spec(name: "猫咪午睡.jpg", kind: .image, size: 3_150_000, daysAgo: 0.5),
        Spec(name: "海边.jpg", kind: .image, size: 5_600_000, daysAgo: 1),
        Spec(name: "生日蛋糕.jpg", kind: .image, size: 2_900_000, daysAgo: 2),
        Spec(name: "设计稿-首页.png", kind: .image, size: 1_800_000, daysAgo: 2.5, from: ["https://www.figma.com/file/abc"]),
        Spec(name: "海报.png", kind: .image, size: 2_200_000, daysAgo: 3, from: ["https://static.canva.cn/x.png", "https://www.canva.cn/design/abc"]),
        Spec(name: "AI 插画.png", kind: .image, size: 2_600_000, daysAgo: 1.5, from: ["https://files.oaiusercontent.com/x.png", "https://chatgpt.com/c/abc"]),
        Spec(name: "微信图片_20261009.jpg", kind: .image, size: 860_000, daysAgo: 2, from: ["https://wx.qq.com/cgi-bin/x"]),
        Spec(name: "小红书收藏.jpg", kind: .image, size: 740_000, daysAgo: 4, from: ["https://sns-img.xhscdn.com/x.jpg", "https://www.xiaohongshu.com/explore/abc"]),
        Spec(name: "截屏 2026-10-11 上午9.41.png", kind: .image, size: 1_100_000, daysAgo: 0.1, screenshot: true),
        Spec(name: "截屏 2026-10-10 下午3.12.png", kind: .image, size: 920_000, daysAgo: 1, screenshot: true),
        Spec(name: "截屏 2026-08-02 上午11.05.png", kind: .image, size: 1_300_000, daysAgo: 70, screenshot: true),
        Spec(name: "截屏 2026-07-21 下午8.30.png", kind: .image, size: 1_050_000, daysAgo: 82, screenshot: true),
        Spec(name: "旅行 Vlog.mov", kind: .video, size: 1_820_000_000, daysAgo: 120),
        Spec(name: "会议录屏.mov", kind: .video, size: 640_000_000, daysAgo: 5),
        Spec(name: "毕业典礼.mp4", kind: .video, size: 980_000_000, daysAgo: 200),
        Spec(name: "晨间散步.mp3", kind: .music, size: 8_400_000, daysAgo: 10),
        Spec(name: "钢琴练习.m4a", kind: .music, size: 5_100_000, daysAgo: 20),
        Spec(name: "年度报告 2026.pdf", kind: .pdf, size: 13_700_000, daysAgo: 6, from: ["https://mail-attachment.googleusercontent.com/x", "https://mail.google.com/mail/u/0/"]),
        Spec(name: "租房合同.pdf", kind: .pdf, size: 6_100_000, daysAgo: 7, from: ["https://mail.qq.com/cgi-bin/download"]),
        Spec(name: "论文初稿 v4.pdf", kind: .pdf, size: 8_600_000, daysAgo: 8),
        Spec(name: "品牌手册.pdf", kind: .pdf, size: 9_400_000, daysAgo: 9, from: ["https://www.feishu.cn/file/abc"]),
        Spec(name: "发票-十月.pdf", kind: .pdf, size: 420_000, daysAgo: 3, from: ["https://mail.163.com/js6/read"]),
        Spec(name: "季度复盘.docx", kind: .doc, size: 2_300_000, daysAgo: 4, from: ["https://www.dingtalk.com/file"]),
        Spec(name: "项目素材.zip", kind: .archive, size: 380_000_000, daysAgo: 45, from: ["https://pan.baidu.com/s/abc"]),
        Spec(name: "照片备份.zip", kind: .archive, size: 1_200_000_000, daysAgo: 90, from: ["https://www.alipan.com/s/abc"]),
        Spec(name: "source-code.zip", kind: .archive, size: 24_000_000, daysAgo: 12, from: ["https://codeload.github.com/x", "https://github.com/hanson-zz/Shiduo"]),
        Spec(name: "WeChatMac.dmg", kind: .installer, size: 498_000_000, daysAgo: 40, from: ["https://dldir1.qq.com/weixin/mac/WeChatMac.dmg", "https://weixin.qq.com/"]),
        Spec(name: "Figma.dmg", kind: .installer, size: 312_000_000, daysAgo: 60, from: ["https://desktop.figma.com/mac/Figma.dmg", "https://www.figma.com/downloads/"]),
        Spec(name: "Python-3.13.pkg", kind: .installer, size: 71_000_000, daysAgo: 33, from: ["https://www.python.org/ftp/python/3.13.0/x.pkg"]),
    ]

    /// 生成示例文件（已存在就跳过），返回对应的 FileItem。
    static func makeItems() -> [FileItem] {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [FileItem] = []
        for (index, spec) in specs.enumerated() {
            let url = folder.appendingPathComponent(spec.name)
            if !fm.fileExists(atPath: url.path) { write(spec, index: index, to: url) }
            let date = Date().addingTimeInterval(-spec.daysAgo * 86_400)
            let type = UTType(filenameExtension: url.pathExtension)
            let tree = type.map { [$0.identifier] + $0.supertypes.map(\.identifier) } ?? []
            result.append(FileItem(
                path: url.path, name: spec.name, size: spec.size,
                contentType: type?.identifier, typeTree: tree,
                modified: date, created: date, lastUsed: spec.daysAgo > 30 ? nil : date, added: date,
                whereFroms: spec.from, isScreenshot: spec.screenshot, bundleID: nil, isDirectory: false
            ))
        }
        return result
    }

    private static func write(_ spec: Spec, index: Int, to url: URL) {
        switch spec.kind {
        case .image:
            let colors = palettes[index % palettes.count]
            let image = gradientImage(colors: colors, seed: index, screenshot: spec.screenshot)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                let data = url.pathExtension == "png"
                    ? rep.representation(using: .png, properties: [:])
                    : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                try? data?.write(to: url)
            }
        case .pdf:
            writePDF(title: (spec.name as NSString).deletingPathExtension, to: url)
        default:
            try? Data(count: 1024).write(to: url)
        }
    }

    private static func gradientImage(colors: [NSColor], seed: Int, screenshot: Bool) -> NSImage {
        let size = NSSize(width: 800, height: screenshot ? 500 : 600)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: CGFloat(30 + seed * 37 % 120))
            // 几个柔和的圆，看起来像照片的光斑。
            for i in 0..<5 {
                let r = CGFloat(80 + (seed * 53 + i * 71) % 160)
                let x = CGFloat((seed * 97 + i * 151) % Int(size.width))
                let y = CGFloat((seed * 61 + i * 113) % Int(size.height))
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - r / 2, y: y - r / 2, width: r, height: r)).fill()
            }
            if screenshot {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 680, height: 380), xRadius: 18, yRadius: 18).fill()
                NSColor.black.withAlphaComponent(0.12).setFill()
                for row in 0..<6 {
                    NSBezierPath(roundedRect: NSRect(x: 100, y: 380 - CGFloat(row) * 50, width: CGFloat(520 - row * 40), height: 18), xRadius: 9, yRadius: 9).fill()
                }
            }
            return true
        }
    }

    private static func writePDF(title: String, to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        NSColor(calibratedRed: 0.30, green: 0.45, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 700, width: 595, height: 142).fill()
        (title as NSString).draw(at: NSPoint(x: 48, y: 750), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white,
        ])
        NSColor(white: 0.85, alpha: 1).setFill()
        for i in 0..<14 {
            NSRect(x: 48, y: 640 - CGFloat(i) * 34, width: CGFloat(500 - (i % 4) * 60), height: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// 几款系统自带应用，用作“应用程序”预览。
    static func appItems() -> [FileItem] {
        ["Safari", "Notes", "Music", "Photos", "Calendar", "Maps"].compactMap { name in
            let path = "/System/Applications/\(name).app"
            let alt = "/Applications/\(name).app"
            let url = URL(fileURLWithPath: FileManager.default.fileExists(atPath: path) ? path : alt)
            return FileItem(url: url)
        }
    }
}

// MARK: - 把演示数据放进各个状态对象

extension LibraryStore {
    func applyDemoDashboard() {
        let all = Demo.makeItems()
        demoItems = all
        remember(all)
        func of(_ c: FileCategory) -> [FileItem] { all.filter { $0.category == c } }
        let apps = Demo.appItems()
        remember(apps)
        totals = [
            .images: CategoryTotal(count: 2_280, bytes: 2_810_000_000),
            .videos: CategoryTotal(count: 162, bytes: 11_210_000_000),
            .music: CategoryTotal(count: 34, bytes: 82_700_000),
            .documents: CategoryTotal(count: 201, bytes: 1_160_000_000),
            .archives: CategoryTotal(count: 93, bytes: 630_300_000),
            .apps: CategoryTotal(count: 110, bytes: 14_310_000_000),
        ]
        previews = [
            .images: Array(of(.images).filter { !$0.isScreenshot }.prefix(3)),
            .videos: Array(of(.videos).prefix(3)),
            .music: Array(of(.music).prefix(3)),
            .documents: Array(of(.documents).prefix(3)),
            .archives: Array(of(.archives).prefix(3)),
            .apps: Array(apps.prefix(3)),
        ]
        sourceGroups = SourceGroup.make(from: all)
        let byDate = all.sorted { $0.sortDate > $1.sortDate }
        shelves = [
            Shelf(id: "screenshots", title: "最近截图", symbol: "camera.viewfinder",
                  items: byDate.filter(\.isScreenshot), target: .screenshots),
            Shelf(id: "images", title: "最近的图片", symbol: "photo",
                  items: byDate.filter { $0.isImage && !$0.isScreenshot }, target: .category(.images)),
        ]
        dashboardLoaded = true

        let old = Date().addingTimeInterval(-30 * 86_400)
        cleanup.cards = [
            CleanupCard(kind: .installers, items: all.filter { ["dmg", "pkg"].contains($0.ext) }),
            CleanupCard(kind: .oldDownloads, items: all.filter { $0.ext == "zip" && $0.sortDate < old }),
            CleanupCard(kind: .oldScreenshots, items: all.filter { $0.isScreenshot && $0.sortDate < old }),
            CleanupCard(kind: .bigOldVideos, items: all.filter { $0.category == .videos && $0.size > 900_000_000 }),
            CleanupCard(kind: .unusedApps, items: []),
        ]
        cleanup.hasScanned = true

        let images = of(.images).filter { !$0.isScreenshot }
        if images.count >= 4 {
            duplicates.groups = [
                FileGroup(id: "demo-dup-1", title: "2 份 · \(images[0].sizeText)", items: [images[0], images[1]]),
                FileGroup(id: "demo-dup-2", title: "2 份 · \(images[2].sizeText)", items: [images[2], images[3]]),
            ]
            duplicates.hasScanned = true
        }
    }

    func applyDemo(_ target: SidebarItem) {
        if demoItems.isEmpty { applyDemoDashboard() }
        let all = demoItems
        switch target {
        case .category(let c): items = all.filter { $0.category == c }
        case .screenshots: items = all.filter(\.isScreenshot)
        case .downloads: items = all.filter { !$0.whereFroms.isEmpty }
        case .largeFiles: items = all.filter { $0.size > 100_000_000 }
        default: items = []
        }
        isLoading = false
    }

    func applyDemoSearch(_ text: String) {
        if demoItems.isEmpty { applyDemoDashboard() }
        searchText = text
        let query = QueryParser().parse(text)
        activeQuery = query
        items = demoItems.filter { item in
            query.kinds.isEmpty || query.kinds.contains { kind in
                switch kind {
                case .category(let c): return item.category == c
                case .screenshot: return item.isScreenshot
                case .extensions(let exts, _): return exts.contains(item.ext)
                }
            }
        }.filter { item in query.minSize.map { item.size >= $0 } ?? true }
        isLoading = false
    }

    /// 启动时按 --page 打开对应页面。
    func startDemo() {
        if Demo.isDark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        applyDemoDashboard()
        switch Demo.page {
        case "images": selection = .category(.images)
        case "downloads": selection = .downloads
        case "cleanup": selection = .cleanup
        case "duplicates": selection = .duplicates
        case "search": applyDemoSearch("上周超过5MB的pdf")
        default: selection = .home
        }
        if let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 920), display: true)
        }
    }
}
