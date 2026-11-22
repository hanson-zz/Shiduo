import AppKit
import Foundation

/// 演示模式里的「工作区」：在临时目录里真的建几个来源文件夹和文件，工作区指向它们，
/// 页面上的数字都是真实扫描出来的（不是写死的）。--page=workspace 是有数据的样子，--page=workspace-empty 是空引导。
extension LibraryStore {
    func applyDemoWorkspace(empty: Bool) {
        let fm = FileManager.default
        let en = Demo.english
        let root = Demo.folder.appendingPathComponent(en ? "Workspace" : "工作区", isDirectory: true)
        let now = Date()

        struct DemoSource {
            let name: String
            let kind: WorkspaceSourceKind
            let files: [(String, Int64)]
            let subfolders: [String]
            let hoursAgo: Double
            var offline = false
        }

        func many(_ zh: String, _ enName: String, _ ext: String, _ count: Int, _ size: Int64) -> [(String, Int64)] {
            var out: [(String, Int64)] = []
            for n in 1...count {
                let base: String = en ? "\(enName) \(n)" : "\(zh) \(n)"
                out.append((base + "." + ext, size + Int64(n) * 37_000))
            }
            return out
        }

        var designFiles: [(String, Int64)] = [
            (en ? "Key Visual.png" : "包装主视觉.png", 8_400_000), (en ? "Box Dieline.png" : "包装结构图.png", 2_100_000),
            (en ? "Label.ai" : "标签.ai", 36_000_000), (en ? "Logo.psd" : "标志.psd", 120_000_000),
        ]
        designFiles += many("配色方案", "Palette", "png", 6, 1_600_000)
        designFiles += many("海报", "Poster", "jpg", 5, 3_200_000)
        designFiles.append((en ? "Brand Guide.pdf" : "品牌手册.pdf", 18_000_000))
        designFiles.append(("README.md", 6_000))

        var footageFiles: [(String, Int64)] = many("样机视频", "Mockup Clip", "mp4", 4, 420_000_000)
        footageFiles += many("实拍", "Shot", "jpg", 8, 6_800_000)
        footageFiles.append((en ? "Comparison.mp4" : "效果对比.mp4", 260_000_000))

        let clientFiles: [(String, Int64)] = [
            (en ? "Proposal Quote.pdf" : "方案报价.pdf", 2_400_000), (en ? "Cost Sheet.xlsx" : "成本表.xlsx", 420_000),
            (en ? "Contract.docx" : "合同.docx", 380_000), (en ? "Meeting Notes.md" : "会议纪要.md", 12_000),
            (en ? "Brief.pages" : "需求说明.pages", 1_900_000), (en ? "Timeline.numbers" : "排期.numbers", 640_000),
            (en ? "Archive.zip" : "往来资料.zip", 86_000_000),
        ]

        var refFiles: [(String, Int64)] = many("参考版式", "Layout Ref", "jpg", 7, 2_300_000)
        refFiles += many("材质测试", "Material Test", "jpg", 5, 4_100_000)
        refFiles.append((en ? "Moodboard.pdf" : "情绪板.pdf", 9_800_000))
        refFiles.append(("installer.dmg", 210_000_000))

        let design = DemoSource(name: en ? "Designs" : "设计稿", kind: .desktop, files: designFiles,
                                subfolders: [en ? "Drafts" : "草稿", en ? "Exports" : "导出", en ? "Fonts" : "字体"], hoursAgo: 2)
        let footage = DemoSource(name: en ? "Footage" : "实拍素材", kind: .external, files: footageFiles,
                                 subfolders: [en ? "Day 1" : "第一天", en ? "Day 2" : "第二天"], hoursAgo: 30, offline: true)
        let client = DemoSource(name: en ? "Client Files" : "客户资料", kind: .iCloud, files: clientFiles,
                                subfolders: [en ? "Invoices" : "发票", en ? "Signed" : "已签"], hoursAgo: 5)
        let refs = DemoSource(name: en ? "References" : "参考图", kind: .downloads, files: refFiles, subfolders: [], hoursAgo: 8)

        let sources = [design, footage, client, refs]
        var made: [WorkspaceSource] = []
        var offline: Set<UUID> = []
        for (si, spec) in sources.enumerated() {
            let dir = root.appendingPathComponent(spec.name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, sub) in spec.subfolders.enumerated() {
                let subURL = dir.appendingPathComponent(sub, isDirectory: true)
                try? fm.createDirectory(at: subURL, withIntermediateDirectories: true)
                try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-(spec.hoursAgo + 4 + Double(i)) * 3600)],
                                      ofItemAtPath: subURL.path)
            }
            for (i, file) in spec.files.enumerated() {
                // 一部分文件放进子文件夹里（扫描是整棵树）。
                let parent = (!spec.subfolders.isEmpty && i % 3 == 2)
                    ? dir.appendingPathComponent(spec.subfolders[i % spec.subfolders.count], isDirectory: true) : dir
                let url = parent.appendingPathComponent(file.0)
                if !fm.fileExists(atPath: url.path) { Demo.writeDemoFile(url: url, seed: si * 11 + i, size: file.1) }
                let date = now.addingTimeInterval(-(spec.hoursAgo + Double(i) * 1.7) * 3600)
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            var source = WorkspaceSource(path: dir.path, kind: spec.kind)
            if spec.kind == .external {
                source.volumeUUID = "DEMO-0000-SHIDUO"
                source.volumeName = en ? "Sandisk Drive" : "闪迪移动硬盘"
                source.volumeCapacity = 1_000_000_000_000
                source.relativePath = spec.name
            }
            if spec.offline {
                // 硬盘「拔掉了」：显示上次（真实）扫描的缓存。
                source.stats = WorkspaceScanner.scan(root: dir)?.stats
                offline.insert(source.id)
            }
            made.append(source)
        }

        let main = Workspace(name: WorkspaceLogic.defaultName, colorIndex: WorkspaceLogic.defaultColorIndex,
                             symbol: "folder", sources: empty ? [] : made)
        let visits = Workspace(name: en ? "Client Visit Videos" : "客户拜访视频", colorIndex: 4, symbol: "film",
                               sources: empty ? made.filter { offline.contains($0.id) } : [])
        let quotes = Workspace(name: en ? "Year-end Quotes" : "年底报价", colorIndex: 3, symbol: "doc.text")
        WorkspaceStore.shared.setDemo([main, visits, quotes], offline: offline)
        selection = .workspace(main.id)
    }
}
