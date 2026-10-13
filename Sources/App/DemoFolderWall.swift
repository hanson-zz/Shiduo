import AppKit
import Foundation

/// 演示模式里的「文件夹墙」：在临时目录里造几个有代表性的文件夹并固定，用来截图。
extension LibraryStore {
    func applyDemoFolderWall() {
        let fm = FileManager.default
        let root = Demo.folder.appendingPathComponent(Demo.english ? "Folder Wall" : "文件夹墙", isDirectory: true)
        let cloudRoot = Demo.folder.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let en = Demo.english

        struct DemoFolder {
            let name: String
            var parent: URL
            let files: [(String, Int64)]
            var subfolders: [String] = []
            let hoursAgo: Double
        }

        let photos = (0..<6).map { (en ? "Trip \($0 + 1).jpg" : "旅行 \($0 + 1).jpg", Int64(3_200_000 + $0 * 180_000)) }
        let cats = (0..<5).map { (en ? "Cat \($0 + 1).jpg" : "猫咪 \($0 + 1).jpg", Int64(2_600_000 + $0 * 90_000)) }
        let shots = (0..<4).map { (en ? "Screenshot \($0 + 1).png" : "截屏 \($0 + 1).png", Int64(1_100_000)) }
        let folders: [DemoFolder] = [
            DemoFolder(name: en ? "Kyoto Trip" : "京都旅行", parent: root, files: photos, hoursAgo: 2),
            DemoFolder(name: en ? "Work Docs" : "工作文稿", parent: root,
                       files: [(en ? "Proposal.pdf" : "提案.pdf", 4_200_000), (en ? "Quarterly Review.docx" : "季度复盘.docx", 2_300_000),
                               (en ? "Meeting Notes.md" : "会议记录.md", 12_000), (en ? "Budget.xlsx" : "预算.xlsx", 380_000)],
                       subfolders: [en ? "Archive" : "归档", en ? "Contracts" : "合同"], hoursAgo: 5),
            DemoFolder(name: en ? "Design Assets" : "设计素材", parent: root,
                       files: [("Inter.ttf", 820_000), ("Noto Serif.otf", 9_400_000), ("Brand.sketch", 18_000_000),
                               ("Landing.fig", 26_000_000), ("Logo.ai", 4_800_000)], hoursAgo: 26),
            DemoFolder(name: en ? "Installers" : "安装包", parent: root,
                       files: [("WeChatMac.dmg", 498_000_000), ("Figma.dmg", 312_000_000), (en ? "Project Assets.zip" : "项目素材.zip", 380_000_000)],
                       hoursAgo: 72),
            DemoFolder(name: en ? "Cats" : "猫咪", parent: root, files: cats, hoursAgo: 30),
            DemoFolder(name: en ? "iCloud Drive" : "iCloud 云盘", parent: cloudRoot,
                       files: [(en ? "Lease Agreement.pdf" : "租房合同.pdf", 6_100_000), (en ? "Travel Plan.pdf" : "旅行计划.pdf", 1_200_000)],
                       subfolders: [en ? "Shared" : "共享"], hoursAgo: 50),
            DemoFolder(name: en ? "Screenshots" : "截图", parent: root, files: shots, hoursAgo: 8),
            DemoFolder(name: en ? "Shiduo Project" : "拾掇项目", parent: root,
                       files: [("README.md", 8_000), ("project.yml", 2_000)],
                       subfolders: ["Sources", "Resources", "Tests", "docs"], hoursAgo: 120),
        ]

        var paths: [String] = []
        for (fi, folder) in folders.enumerated() {
            let dir = folder.parent.appendingPathComponent(folder.name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (si, sub) in folder.subfolders.enumerated() {
                let subURL = dir.appendingPathComponent(sub, isDirectory: true)
                try? fm.createDirectory(at: subURL, withIntermediateDirectories: true)
                let date = Date().addingTimeInterval(-(folder.hoursAgo + 3 + Double(si)) * 3600)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: subURL.path)
            }
            for (i, file) in folder.files.enumerated() {
                let url = dir.appendingPathComponent(file.0)
                if !fm.fileExists(atPath: url.path) {
                    Demo.writeDemoFile(url: url, seed: fi * 7 + i, size: file.1)
                }
                let date = Date().addingTimeInterval(-(folder.hoursAgo + Double(i)) * 3600)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            paths.append(dir.path)
        }
        pinnedFolders = paths
        selection = .folderWall
    }
}

extension Demo {
    /// 图片写成真的渐变图；其他文件写成稀疏文件，显示的大小就是 size。
    static func writeDemoFile(url: URL, seed: Int, size: Int64) {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "png"].contains(ext) {
            let palettes: [[NSColor]] = [
                [.systemPink, .systemOrange], [.systemTeal, .systemBlue], [.systemPurple, .systemIndigo],
                [.systemGreen, .systemTeal], [.systemYellow, .systemOrange], [.systemOrange, .systemRed],
            ]
            let colors = palettes[seed % palettes.count]
            let image = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
                NSGradient(colors: colors)?.draw(in: rect, angle: CGFloat(30 + seed * 37 % 120))
                for i in 0..<5 {
                    let r = CGFloat(80 + (seed * 53 + i * 71) % 160)
                    let x = CGFloat((seed * 97 + i * 151) % 800)
                    let y = CGFloat((seed * 61 + i * 113) % 600)
                    NSColor.white.withAlphaComponent(0.2).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x - r / 2, y: y - r / 2, width: r, height: r)).fill()
                }
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                let data = ext == "png" ? rep.representation(using: .png, properties: [:])
                    : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                try? data?.write(to: url)
            }
            return
        }
        FileManager.default.createFile(atPath: url.path, contents: Data("demo".utf8))
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(max(size, 4)))
            try? handle.close()
        }
    }
}
