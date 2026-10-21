import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据

/// 文件夹卡片上「探出来」的是什么。
enum FolderLook: Equatable {
    case photos     // 照片探出来
    case papers     // 文稿纸张
    case tiles      // 字体、设计素材：色卡
    case archive    // 压缩包、安装包：拉链
    case cloud      // iCloud 云盘
    case plain
}

/// 文件夹图标：拾掇风格 / 系统图标。全局设置（设置 › 通用 › 文件夹图标、文件夹墙右下角都能改，存在 UserDefaults），
/// 主窗口网格 / 列表、简介、搜索、暂存架、文件夹墙里所有文件夹都跟着它。键名沿用以前文件夹墙的，旧的选择保留。
enum FolderWallIconStyle: String, CaseIterable, Identifiable {
    /// 拾掇自己画的文件夹（文件夹墙上探出照片、文稿……，别处是不探出内容的同款文件夹）。
    case shiduo
    /// 访达里的系统图标（自定义图标、「文件夹上色」的结果都会显示）。
    case system

    static let key = "folderWallIconStyle"
    var id: Self { self }
    var title: String {
        switch self {
        case .shiduo: return String(localized: "拾掇风格")
        case .system: return String(localized: "系统图标")
        }
    }
}

/// 一个固定文件夹的概况：只读第一层，不递归，打开页面很快。
struct FolderSummary: Equatable {
    let path: String
    var name: String
    var fileCount = 0
    var folderCount = 0
    var bytes: Int64 = 0
    var archiveBytes: Int64 = 0
    var updated: Date?
    var previews: [URL] = []
    var look: FolderLook = .plain
    /// 访达标签颜色编号（0 = 没有）。
    var label = 0
    /// 已经读过文件夹内容（没读到之前不当成空文件夹）。
    var loaded = false

    static func load(_ path: String) -> FolderSummary {
        let url = URL(fileURLWithPath: path)
        var s = FolderSummary(path: path, name: FileManager.default.displayName(atPath: path))
        s.label = (try? url.resourceValues(forKeys: [.labelNumberKey]).labelNumber) ?? 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return s }
        s.loaded = true

        var images: [(URL, Date)] = []
        var docs: [(URL, Date)] = []
        /// 设计稿、压缩包、其他文件（探出真实文件图标用）。
        var designFiles: [(URL, Date)] = []
        var archiveFiles: [(URL, Date)] = []
        var others: [(URL, Date)] = []
        var archives = 0, design = 0
        for child in children {
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            let date = v.contentModificationDate ?? .distantPast
            if let updated = s.updated { s.updated = max(updated, date) } else { s.updated = date }
            if v.isDirectory == true && v.isPackage != true {
                s.folderCount += 1
                continue
            }
            s.fileCount += 1
            let size = Int64(v.fileSize ?? 0)
            s.bytes += size
            guard let type = v.contentType else { continue }
            if type.conforms(to: .image) {
                images.append((child, date))
            } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) || ["dmg", "pkg", "zip", "rar", "7z"].contains(child.pathExtension.lowercased()) {
                archives += 1
                s.archiveBytes += size
                archiveFiles.append((child, date))
            } else if type.conforms(to: .font) || ["sketch", "fig", "psd", "ai", "xd", "ttf", "otf"].contains(child.pathExtension.lowercased()) {
                design += 1
                designFiles.append((child, date))
            } else if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
                        || type.conforms(to: .spreadsheet) || ["doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "md"].contains(child.pathExtension.lowercased()) {
                docs.append((child, date))
            } else {
                others.append((child, date))
            }
        }

        let files = max(s.fileCount, 1)
        if path.contains("/Library/Mobile Documents/") {
            s.look = .cloud
        } else if !images.isEmpty && Double(images.count) / Double(files) >= 0.3 {
            s.look = .photos
        } else if archives > 0 && Double(archives) / Double(files) >= 0.3 {
            s.look = .archive
        } else if design > 0 && Double(design) / Double(files) >= 0.2 {
            s.look = .tiles
        } else if !docs.isEmpty {
            s.look = .papers
        } else if !images.isEmpty {
            s.look = .photos
        }
        func newest(_ list: [(URL, Date)], _ n: Int) -> [URL] { list.sorted { $0.1 > $1.1 }.prefix(n).map(\.0) }
        switch s.look {
        case .photos: s.previews = newest(images, 3)
        case .papers: s.previews = newest(docs, 2)
        // 设计 / 云盘 / 归档：探出文件夹里真实文件的图标（图片用缩略图），最多 3 个。
        case .tiles:
            s.previews = Self.pick([newest(designFiles, 2), newest(images, 1), newest(docs + others + archiveFiles, 3)])
        case .cloud:
            s.previews = Self.pick([newest(docs, 2), newest(others + designFiles + archiveFiles, 3), newest(images, 3)])
        case .archive:
            s.previews = Self.pick([newest(archiveFiles, 2), newest(others + docs + designFiles, 3), newest(images, 3)])
        case .plain: break
        }
        return s
    }

    /// 按优先级依次取，凑够 3 个不重复的。
    private static func pick(_ groups: [[URL]], limit: Int = 3) -> [URL] {
        var out: [URL] = []
        for url in groups.joined() where !out.contains(url) {
            out.append(url)
            if out.count == limit { break }
        }
        return out
    }

    /// 文件夹里一个文件、一个子文件夹都没有（空状态）。
    var isEmpty: Bool { loaded && fileCount == 0 && folderCount == 0 }
}

@MainActor
final class FolderWallModel: ObservableObject {
    static let shared = FolderWallModel()

    @Published private(set) var summaries: [String: FolderSummary] = [:]
    /// 照片取色的结果。
    @Published private(set) var photoTints: [String: NSColor] = [:]
    /// 手动选的颜色（下标见 FolderPalette）。
    @Published var manualColors: [String: Int] = (UserDefaults.standard.dictionary(forKey: "folderWall.colors") as? [String: Int]) ?? [:] {
        didSet { UserDefaults.standard.set(manualColors, forKey: "folderWall.colors") }
    }
    /// 用色盘自己调的颜色（十六进制 RRGGBB），优先于预设颜色。
    @Published var customColors: [String: String] = (UserDefaults.standard.dictionary(forKey: "folderWall.customColors") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(customColors, forKey: "folderWall.customColors") }
    }

    func setPreset(_ index: Int?, for path: String) {
        customColors[path] = nil
        manualColors[path] = index
    }

    func setCustom(_ color: NSColor, for path: String) {
        manualColors[path] = nil
        customColors[path] = FolderPalette.hex(color)
    }

    func movePath(_ old: String, to new: String) {
        if let color = manualColors.removeValue(forKey: old) { manualColors[new] = color }
        if let color = customColors.removeValue(forKey: old) { customColors[new] = color }
        FolderIconService.shared.movePath(old, to: new)
    }

    /// 文件夹被「立即删除」以后：去掉它（和它里面的文件夹）记下的颜色和概要。
    func forget(where gone: (String) -> Bool) {
        let manual = manualColors.filter { !gone($0.key) }
        if manual.count != manualColors.count { manualColors = manual }
        let custom = customColors.filter { !gone($0.key) }
        if custom.count != customColors.count { customColors = custom }
        let left = summaries.filter { !gone($0.key) }
        if left.count != summaries.count { summaries = left }
        let tints = photoTints.filter { !gone($0.key) }
        if tints.count != photoTints.count { photoTints = tints }
    }

    /// 打开系统色盘，拖动时实时改这个文件夹的颜色。
    func openColorPanel(for s: FolderSummary) {
        FolderColorPanel.shared.open(initial: tint(for: s)) { [weak self] color in
            self?.setCustom(color, for: s.path)
        }
    }

    /// 系统图标要重新读的时候加一（重新读概要、拾掇改了访达图标）。
    @Published private(set) var iconRevision = 0

    func refreshIcons() { iconRevision &+= 1 }

    func reload(_ paths: [String]) {
        iconRevision &+= 1
        Task.detached(priority: .userInitiated) {
            var result: [String: FolderSummary] = [:]
            for path in paths { result[path] = FolderSummary.load(path) }
            await MainActor.run {
                self.summaries = result
                self.iconRevision &+= 1
                for s in result.values where s.look == .photos { self.pickTint(s) }
            }
        }
    }

    private func pickTint(_ s: FolderSummary) {
        guard let first = s.previews.first, photoTints[s.path] == nil else { return }
        Task {
            guard let image = await ThumbnailService.shared.thumbnail(for: first, size: 48),
                  let color = FolderPalette.average(image) else { return }
            photoTints[s.path] = color
        }
    }

    func tint(for s: FolderSummary) -> NSColor {
        if let hex = customColors[s.path], let c = FolderPalette.color(hex: hex) { return c }
        if let i = manualColors[s.path], FolderPalette.colors.indices.contains(i) { return FolderPalette.colors[i].1 }
        if let tag = FolderPalette.finderLabel(s.label) { return tag }
        switch s.look {
        case .photos: return photoTints[s.path] ?? FolderPalette.colors[s.name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 7].1
        case .papers: return NSColor(srgbRed: 0.31, green: 0.41, blue: 0.41, alpha: 1)
        case .archive: return NSColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1)
        case .cloud: return NSColor(srgbRed: 0.70, green: 0.82, blue: 0.94, alpha: 1)
        case .tiles: return NSColor(srgbRed: 0.96, green: 0.53, blue: 0.36, alpha: 1)
        case .plain: return NSColor(srgbRed: 0.56, green: 0.53, blue: 0.93, alpha: 1)
        }
    }
}

/// 系统色盘（NSColorPanel）的小帮手：一次只给一个文件夹调色。
@MainActor
final class FolderColorPanel: NSObject {
    static let shared = FolderColorPanel()
    private var onChange: ((NSColor) -> Void)?

    func open(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = initial
        self.onChange = onChange
        panel.title = String(localized: "文件夹颜色")
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

enum FolderPalette {
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let colors: [(String, NSColor)] = [
        (String(localized: "珊瑚"), NSColor(srgbRed: 0.94, green: 0.45, blue: 0.39, alpha: 1)),
        (String(localized: "橙"), NSColor(srgbRed: 0.96, green: 0.53, blue: 0.36, alpha: 1)),
        (String(localized: "麦黄"), NSColor(srgbRed: 0.93, green: 0.75, blue: 0.43, alpha: 1)),
        (String(localized: "松绿"), NSColor(srgbRed: 0.44, green: 0.64, blue: 0.51, alpha: 1)),
        (String(localized: "天蓝"), NSColor(srgbRed: 0.53, green: 0.70, blue: 0.92, alpha: 1)),
        (String(localized: "淡紫"), NSColor(srgbRed: 0.56, green: 0.53, blue: 0.93, alpha: 1)),
        (String(localized: "粉"), NSColor(srgbRed: 0.93, green: 0.50, blue: 0.59, alpha: 1)),
        (String(localized: "石墨"), NSColor(srgbRed: 0.31, green: 0.41, blue: 0.41, alpha: 1)),
        (String(localized: "银灰"), NSColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1)),
    ]

    /// 访达标签：1 灰 2 绿 3 紫 4 蓝 5 黄 6 红 7 橙。
    static func finderLabel(_ n: Int) -> NSColor? {
        switch n {
        case 1: return colors[8].1
        case 2: return colors[3].1
        case 3: return colors[5].1
        case 4: return colors[4].1
        case 5: return colors[2].1
        case 6: return colors[0].1
        case 7: return colors[1].1
        default: return nil
        }
    }

    /// 图片的平均色，调成适合做文件夹的亮度和饱和度。
    static func average(_ image: NSImage) -> NSColor? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let c = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(max(s * 1.3, 0.35), 0.62), brightness: min(max(b, 0.72), 0.92), alpha: 1)
    }
}

extension NSColor {
    func mixed(_ other: NSColor, _ t: CGFloat) -> NSColor {
        (usingColorSpace(.sRGB) ?? self).blended(withFraction: t, of: other) ?? self
    }

    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.70
    }
}

// MARK: - 页面

/// 文件夹墙：常用文件夹的卡片墙（以前侧边栏的「固定文件夹」也在这里，是同一份 pinnedFolders）。免费。
struct FolderWallView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var model = FolderWallModel.shared
    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var transfer = ShelfTransfer.shared
    @State private var query = ""
    @AppStorage("folderWall.sort") private var sort: Sort = .recent
    /// 卡片大小（右下角的滑块、⌘+ / ⌘-），存在 UserDefaults。
    @AppStorage(LibraryStore.wallTileSizeKey) private var tileSize: Double = FolderWallView.defaultTileSize
    /// 卡片图标：拾掇风格 / 系统图标（右下角滑块旁的小菜单、设置 › 通用 › 文件夹墙）。
    @AppStorage(FolderWallIconStyle.key) private var iconStyle: FolderWallIconStyle = .shiduo
    /// 「文件夹上色」改了访达图标：系统图标模式下重新读图标。
    @ObservedObject private var folderIcons = FolderIconService.shared
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool
    @State private var selectedPath: String?
    @State private var renamingPath: String?
    @State private var gridWidth: CGFloat = 900
    @State private var wallTargeted = false

    static let defaultTileSize: Double = 122
    /// 卡片拖动排序时放进拖动内容里的前缀（不是文件，拖到别的 App 里没用）。
    static let tilePrefix = "shiduo-folder-wall:"

    enum Sort: String, CaseIterable, Identifiable {
        case recent, name, size, manual
        var id: Self { self }
        var title: String {
            switch self {
            case .recent: return String(localized: "最近")
            case .name: return String(localized: "名称")
            case .size: return String(localized: "大小")
            case .manual: return String(localized: "自定")
            }
        }
        var symbol: String {
            switch self {
            case .recent: return "clock"
            case .name: return "textformat"
            case .size: return "internaldrive"
            case .manual: return "hand.draw"
            }
        }
    }

    /// 卡片里文件夹本体的宽度（滑块 48–160 对应 77–256pt）。
    private var cardWidth: CGFloat { CGFloat(min(max(tileSize, LibraryStore.wallTileSizeRange.lowerBound), LibraryStore.wallTileSizeRange.upperBound)) * 1.6 }

    private var folders: [FolderSummary] {
        let all = store.pinnedFolders.map { model.summaries[$0] ?? FolderSummary(path: $0, name: FileManager.default.displayName(atPath: $0)) }
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
        }
        switch sort {
        case .recent: return filtered.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return filtered.sorted { $0.bytes > $1.bytes }
        case .manual: return filtered
        }
    }

    /// 每行几张卡片（方向键上下用）。
    private var columns: Int {
        max(1, Int((gridWidth + 20) / (cardWidth + 32 + 20)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if store.pinnedFolders.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardWidth + 32, maximum: cardWidth + 64), spacing: 20)], spacing: 24) {
                        ForEach(folders, id: \.path) { s in
                            FolderCard(summary: s,
                                       tint: model.tint(for: s),
                                       reminderCount: reminders.reminders.filter { $0.path.hasPrefix(s.path + "/") }.count,
                                       width: cardWidth,
                                       iconStyle: iconStyle,
                                       selected: selectedPath == s.path,
                                       renamingPath: $renamingPath,
                                       onSelect: {
                                           selectedPath = s.path
                                           gridFocused = true
                                       },
                                       onDropTile: { moved in reorder(moved, before: s.path) })
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { gridWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { gridWidth = proxy.size.width }
                    })
                    .padding(.horizontal, 24)
                    .padding(.top, 30)
                    .padding(.bottom, 44)
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard press.modifiers.subtracting([.numericPad, .function]).isEmpty else { return .ignored }
                    switch press.key {
                    case .leftArrow: return step(-1)
                    case .rightArrow: return step(1)
                    case .upArrow: return step(-columns)
                    default: return step(columns)
                    }
                }
                // 回车：重命名（和访达一样）；⌘↓ / ⌘O：打开。
                .onKeyPress(.return) {
                    guard let path = selectedPath, NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
                    else { return .ignored }
                    renamingPath = path
                    return .handled
                }
                .onKeyPress(keys: [.downArrow, "o"]) { press in
                    guard press.modifiers.subtracting([.numericPad, .function]) == .command, let path = selectedPath else { return .ignored }
                    open(path)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard selectedPath != nil else { return .ignored }
                    selectedPath = nil
                    return .handled
                }
            }
        }
        // 把文件夹从访达或拾掇的列表拖到墙上：放上墙；拖动卡片到空白处：排到最后。
        .onDrop(of: [.fileURL, .plainText], isTargeted: $wallTargeted) { providers in
            handleWallDrop(providers)
        }
        .overlay {
            if wallTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !store.pinnedFolders.isEmpty { sizeSlider }
        }
        .onAppear { model.reload(store.pinnedFolders) }
        .onChange(of: store.pinnedFolders) { model.reload(store.pinnedFolders) }
        .onChange(of: folderIcons.ledger) { model.refreshIcons() }
        // 拖进卡片的文件移动 / 拷贝完了：重新读一下数量和预览。
        .onChange(of: transfer.isRunning) { if !transfer.isRunning { model.reload(store.pinnedFolders) } }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("/", modifiers: [])
                // 顶部搜索框正在输入时也不抢「/」。
                .disabled(searchFocused || store.searchFieldFocused)
                .opacity(0)
        }
    }

    /// 访达状态栏那样的图标大小滑块：左边小文件夹，右边大文件夹。
    private var sizeSlider: some View {
        HStack(spacing: 6) {
            iconStyleMenu
            Divider()
                .frame(height: 12)
                .padding(.horizontal, 2)
            Image(systemName: "folder.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $tileSize, in: LibraryStore.wallTileSizeRange)
                .controlSize(.mini)
                .frame(width: 96)
                .accessibilityLabel("卡片大小")
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .help("卡片大小（⌘+ / ⌘-）")
    }

    /// 图标样式：拾掇风格 / 系统图标。放在大小滑块左边，同一个胶囊里。
    private var iconStyleMenu: some View {
        Menu {
            Picker("文件夹图标", selection: $iconStyle) {
                ForEach(FolderWallIconStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: iconStyle == .system ? "folder" : "folder.badge.gearshape")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("文件夹图标")
        .accessibilityLabel("文件夹图标")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("文件夹墙")
                    .font(.title.weight(.bold))
                Label("\(store.pinnedFolders.count)", systemImage: "folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("\(model.summaries.values.reduce(0) { $0 + $1.fileCount })", systemImage: "doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.reload(store.pinnedFolders)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
                .accessibilityLabel("刷新")
                Button {
                    store.choosePinnedFolder()
                } label: {
                    Label("添加到文件夹墙", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help(AppShortcut.addToFolderWall.help)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(String(localized: "按名称或路径搜索 \(store.pinnedFolders.count) 个文件夹"), text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    Text("/")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
                .frame(maxWidth: 460)

                Picker("排序", selection: $sort) {
                    ForEach(Sort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("「自定」按你拖动排好的顺序")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("文件夹墙还是空的")
                .font(.title3.weight(.semibold))
            Text("把常用的文件夹放上来，这里会变成一面卡片墙，一眼看到里面有什么。也可以直接把文件夹从访达拖到这里。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                store.choosePinnedFolder()
            } label: {
                Label("添加到文件夹墙", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 操作

    private func open(_ path: String) {
        store.openFolder(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let list = folders
        guard !list.isEmpty else { return .ignored }
        let index = list.firstIndex { $0.path == selectedPath } ?? (offset > 0 ? -1 : list.count)
        let target = min(max(index + offset, 0), list.count - 1)
        selectedPath = list[target].path
        return .handled
    }

    /// 拖动卡片排序：把 moved 排到 target 前面（target 为 nil 排到最后），之后按「自定」顺序显示。
    private func reorder(_ moved: String, before target: String?) {
        var order = store.pinnedFolders
        guard order.contains(moved), moved != target else { return }
        // 先按眼前看到的顺序排好，拖动的结果才和看到的一致。
        if sort != .manual {
            order = folders.map(\.path) + order.filter { path in !folders.contains { $0.path == path } }
        }
        order.removeAll { $0 == moved }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(moved, at: index)
        } else {
            order.append(moved)
        }
        store.pinnedFolders = order
        sort = .manual
    }

    private func handleWallDrop(_ providers: [NSItemProvider]) -> Bool {
        if FolderWallDrop.loadTile(providers, completion: { reorder($0, before: nil) }) { return true }
        return FileDrop.load(providers) { urls in
            let dirs = urls.filter { LibraryStore.isBrowsableFolder($0) }
            for dir in dirs { store.pin(dir.path) }
            if dirs.isEmpty { store.showToast(String(localized: "只有文件夹能放上文件夹墙；文件可以拖到某张卡片上，移进那个文件夹")) }
        }
    }
}

/// 文件夹墙的拖放：卡片之间拖动排序用一段带前缀的文字（不是文件），和拖进来的文件分开。
enum FolderWallDrop {
    /// 是卡片排序的拖动就读出路径交给 completion，返回 true。
    static func loadTile(_ providers: [NSItemProvider], completion: @escaping @MainActor (String) -> Void) -> Bool {
        guard !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }),
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix(FolderWallView.tilePrefix) else { return }
            let path = String(text.dropFirst(FolderWallView.tilePrefix.count))
            Task { @MainActor in completion(path) }
        }
        return true
    }

    static func tileProvider(_ path: String) -> NSItemProvider {
        NSItemProvider(object: (FolderWallView.tilePrefix + path) as NSString)
    }
}

// MARK: - 卡片

struct FolderCard: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var model = FolderWallModel.shared
    let summary: FolderSummary
    let tint: NSColor
    let reminderCount: Int
    /// 文件夹本体的宽度（右下角滑块调）。
    var width: CGFloat = 196
    /// 拾掇风格（自己画的文件夹）还是访达的系统图标。
    var iconStyle: FolderWallIconStyle = .shiduo
    var selected = false
    /// 墙上按回车时设成这张卡片的路径：弹出重命名。
    @Binding var renamingPath: String?
    var onSelect: () -> Void = {}
    /// 别的卡片拖到这张上面：排到它前面。
    var onDropTile: (String) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var renaming = false
    @State private var newName = ""
    /// 「文件夹上色」的颜色和叠加层、别处设置的自定义图标、系统文件夹符号（后台查，缓存）。
    @State private var artVariant: ShiduoFolderVariant?
    @State private var artVersion = 0

    private var height: CGFloat { width * 0.80 }
    /// 小卡片上字也小一点。
    private var nameSize: CGFloat { width < 120 ? 12 : 14 }

    /// 卡片本身（拆开写：整串修饰符太长，编译器类型检查会超时）。
    private var face: some View {
        VStack(spacing: 6) {
            folderArea
                .frame(width: width, height: height)
                .scaleEffect(dropTargeted ? 1.05 : 1)
            Text(summary.name)
                .font(.system(size: nameSize, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: width + 16)
                .padding(.top, 10)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: width + 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering || dropTargeted ? 0.055 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    /// 点按、拖放、右键菜单。
    private var interactive: some View {
        face
            .onHover { h in guard !Demo.isOn else { return }; withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { hovering = h } }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dropTargeted)
            // 和访达一样：点一下选中，双击打开。
            .onTapGesture(count: 2) { openFolder() }
            .onTapGesture { onSelect() }
            // 拖动卡片：在墙上换位置（拖到另一张卡片上，排到它前面）。
            .onDrag { FolderWallDrop.tileProvider(summary.path) }
            // 把文件拖到卡片上：移进这个文件夹（按住 ⌥ 拷贝），⌘Z 可以撤销移动。
            // 光标：按 ⌥ 显示拷贝，不按显示移动（和实际一致）。
            .onDrop(of: [.fileURL, .plainText], delegate: dropDelegate)
            .help(summary.path)
            .contextMenu { menu }
            .onChange(of: renamingPath) {
                guard renamingPath == summary.path else { return }
                renamingPath = nil
                startRename()
            }
            .onReceive(NotificationCenter.default.publisher(for: ThumbnailService.invalidated)) { note in
                guard let paths = note.userInfo?["paths"] as? Set<String>, paths.contains(summary.path) else { return }
                artVersion += 1
            }
            .task(id: "\(summary.path)#\(artVersion)#\(iconStyle.rawValue)") {
                guard iconStyle == .shiduo else { return }
                let resolved = await ShiduoFolderArtCache.shared.variant(summary.path)
                if artVariant != resolved { artVariant = resolved }
            }
    }

    var body: some View {
        interactive
            .accessibilityElement(children: .ignore)
            // 名字和副标题分开读，不在英文界面里读出写死的全角逗号。
            .accessibilityLabel(Text(verbatim: summary.name))
            .accessibilityValue(Text(verbatim: subtitle))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { openFolder() }
            .accessibilityAction(named: Text("重命名")) { startRename() }
            .accessibilityAction(named: Text("从文件夹墙移除")) { store.unpin(summary.path) }
            .alert("重命名文件夹", isPresented: $renaming) {
                TextField("名称", text: $newName)
                Button("重命名") { rename(to: newName) }
                Button("取消", role: .cancel) {}
            }
    }

    /// 拖到卡片上：卡片排序（私有文字）或者把文件移进来（⌥ 拷贝）。
    private var dropDelegate: FileMoveDropDelegate {
        let tile = onDropTile
        return FileMoveDropDelegate(
            enabled: true, targeted: $dropTargeted, types: [.fileURL, .plainText],
            other: { providers in FolderWallDrop.loadTile(providers, completion: { tile($0) }) },
            perform: { urls, copy in moveIn(urls, copy: copy) })
    }

    private var subtitle: String {
        if iconStyle == .shiduo && summary.isEmpty { return String(localized: "空 · 拖入文件即可整理") }
        // 拾掇风格的小卡片不画角标：更新时间（归档是可腾出的空间）收进副标题。
        if iconStyle == .shiduo && width < 120 && reminderCount == 0 {
            if summary.look == .archive && summary.archiveBytes > 0 {
                return String(localized: "可腾出 \(summary.archiveBytes.byteText)")
            }
            if let relative = relativeUpdated {
                return [String(localized: "\(summary.fileCount) 个文件"), relative].joined(separator: " · ")
            }
        }
        var parts = [String(localized: "\(summary.fileCount) 个文件")]
        if reminderCount > 0 {
            parts.append(String(localized: "\(reminderCount) 个提醒"))
        } else if summary.look == .archive && summary.archiveBytes > 0 {
            parts.append(String(localized: "可腾出 \(summary.archiveBytes.byteText)"))
        } else if summary.folderCount > 0 {
            parts.append(String(localized: "\(summary.folderCount) 个子文件夹"))
        }
        return parts.joined(separator: " · ")
    }

    private var badge: String? {
        if summary.look == .archive && summary.archiveBytes > 0 { return "ZIP · \(summary.archiveBytes.byteText)" }
        guard let relative = relativeUpdated else { return nil }
        return String(localized: "\(relative)更新")
    }

    /// 「2 小时前」这样的相对时间（系统按界面语言格式化）。
    private var relativeUpdated: String? {
        guard let date = summary.updated, date > .distantPast else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: min(date, Date().addingTimeInterval(-1)), relativeTo: Date())
    }

    // MARK: 文件夹本体

    @ViewBuilder
    private var folderArea: some View {
        if iconStyle == .system { systemFolder } else { folder }
    }

    /// 系统图标模式：访达里的图标（含自定义图标、「文件夹上色」），只保留悬停上浮、角标和悬停按钮。
    private var systemFolder: some View {
        ZStack {
            SystemFolderIcon(path: summary.path, side: min(width, height * 1.12), revision: model.iconRevision)
                .shadow(color: .black.opacity(hovering ? 0.20 : 0.10), radius: hovering ? 8 : 4, y: hovering ? 6 : 3)
                .scaleEffect(hovering ? 1.04 : 1)
                .offset(y: hovering ? -6 : 0)
            overlays(ink: Color.black.opacity(0.62), light: true,
                     top: max(2, height * 0.06), bottom: max(4, height * 0.16))
        }
        .frame(width: width, height: height)
    }

    /// 拾掇风格 · Liquid Glass：玻璃前片透出后片和探出的真实文件（GlassFolderArt，见 FolderWallGlass.swift）。
    private var folder: some View {
        let m = GlassFolderMetrics(width: width, tint: shownTint, dark: scheme == .dark)
        let ink = m.dark || !m.paleTint ? Color.white : Color.black.opacity(0.62)
        return ZStack(alignment: .topLeading) {
            GlassFolderArt(summary: summary, m: m, hovering: hovering)
            artBadge(m)
            overlays(ink: ink, light: m.paleTint, top: m.ph * 0.075 + 10, bottom: 32,
                     glass: true, showBadge: !m.small && !summary.isEmpty)
                .frame(width: width, height: m.ph)
                .offset(y: m.py)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    /// 卡片颜色：墙上手动选过颜色就用它；否则文件夹在「文件夹上色」里上过色，用那个颜色（和主窗口里一样）。
    private var shownTint: NSColor {
        guard model.customColors[summary.path] == nil, model.manualColors[summary.path] == nil,
              let v = artVariant, v.styled, let color = FolderPalette.color(hex: v.hex) else { return tint }
        return color
    }

    /// 前片左侧的叠加层（上色的 emoji / 图片、自定义图标、系统文件夹符号），和主窗口里的拾掇文件夹一致。
    /// 空文件夹（虚线框）和带压印图标的归档 / 云盘卡片不画，免得挤在一起。
    @ViewBuilder
    private func artBadge(_ m: GlassFolderMetrics) -> some View {
        if let v = artVariant, v.badge != .none, !summary.isEmpty, summary.look != .archive, summary.look != .cloud {
            let box = min(m.ph * (m.small ? 0.40 : 0.44), 44)
            ShiduoFolderBadge(variant: v, image: ShiduoFolderArtCache.shared.badgeImage(summary.path), box: box,
                              center: CGPoint(x: (m.small ? 8 : 14) + box / 2, y: m.py + m.ph * 0.52),
                              canvas: CGSize(width: m.width, height: m.height), dark: m.dark)
        }
    }

    /// 悬停按钮、提醒角标和更新角标。glass = 拾掇风格的磨砂玻璃角标（系统图标模式照旧）。
    private func overlays(ink: Color, light: Bool, top: CGFloat = 16, bottom: CGFloat = 24,
                          glass: Bool = false, showBadge: Bool = true) -> some View {
        let darkGlass = glass && scheme == .dark
        return ZStack {
            if hovering {
                HStack(spacing: 4) {
                    actionButton("pencil", help: String(localized: "重命名"), tint: darkGlass ? Color.white.opacity(0.85) : Color.black.opacity(0.7)) { startRename() }
                    actionButton("folder", help: String(localized: "移动到…"), tint: darkGlass ? Color.white.opacity(0.85) : Color.black.opacity(0.7)) { moveFolder() }
                    if iconStyle == .system {
                        // 系统图标看不到卡片颜色：直接打开「文件夹上色」（Pro，不是 Pro 弹付费页）。
                        actionButton("paintpalette", help: String(localized: "文件夹上色…")) {
                            FolderIconService.shared.openEditor([URL(fileURLWithPath: summary.path, isDirectory: true)], color: tint)
                        }
                    } else {
                        actionButton("paintpalette", help: String(localized: "自定义颜色…"), tint: darkGlass ? Color.white.opacity(0.85) : Color.black.opacity(0.7)) { model.openColorPanel(for: summary) }
                    }
                    actionButton("minus.circle", help: String(localized: "从文件夹墙移除"), tint: .red) { store.unpin(summary.path) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(darkGlass ? Color(white: 0.17).opacity(0.94) : Color.white.opacity(0.92)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(darkGlass ? 0.14 : 0), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, top)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            HStack {
                if reminderCount > 0 {
                    if glass {
                        Label("\(reminderCount)", systemImage: "alarm")
                            .font(.system(size: 11, weight: .semibold))
                            .modifier(GlassBadgeStyle(dark: scheme == .dark))
                    } else {
                        Label("\(reminderCount)", systemImage: "alarm")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(light ? 0.9 : 0.22)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.45)))
                    }
                }
                Spacer()
                if let badge, !hovering, showBadge {
                    if glass {
                        Text(badge)
                            .font(.system(size: 11, weight: summary.look == .archive ? .bold : .medium))
                            .lineLimit(1)
                            .modifier(GlassBadgeStyle(dark: scheme == .dark))
                    } else {
                        Text(badge)
                            .font(.system(size: 11, weight: summary.look == .archive ? .bold : .medium))
                            .foregroundStyle(Color.black.opacity(0.68))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.88)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.5)))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, bottom)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func actionButton(_ symbol: String, help: String, tint: Color = Color.black.opacity(0.7), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var item: FileItem? { FileItem(url: URL(fileURLWithPath: summary.path, isDirectory: true)) }

    /// 右键菜单：和主窗口同一套（打开、在访达中显示、显示简介、拷贝路径……），
    /// 「重命名…」用卡片自己的（墙上记的路径跟着改），多一项「从文件夹墙移除」和颜色。
    @ViewBuilder
    private var menu: some View {
        if let item {
            FileContextMenu(items: [item], context: FileMenuContext(
                rename: { startRename() },
                removeFromWall: { store.unpin(summary.path) }
            )) {
                if iconStyle == .shiduo { colorMenu }
            }
        } else {
            // 文件夹已经不在了（被移走、在没插上的硬盘里）：只能从墙上拿掉。
            Button("从文件夹墙移除") { store.unpin(summary.path) }
        }
    }

    @ViewBuilder
    private var colorMenu: some View {
        Menu("卡片颜色") {
            Button("自动") { model.setPreset(nil, for: summary.path) }
            Divider()
            ForEach(FolderPalette.colors.indices, id: \.self) { i in
                Button(FolderPalette.colors[i].0) { model.setPreset(i, for: summary.path) }
            }
            Divider()
            Button("自定义颜色…") { model.openColorPanel(for: summary) }
        }
        Button("在访达里也用这个颜色") {
            guard let outcome = FolderIconService.shared.quickApply(color: tint, to: [URL(fileURLWithPath: summary.path)]) else { return }
            if !outcome.succeeded.isEmpty { store.showToast(String(localized: "访达里的「\(summary.name)」已换成这个颜色")) }
            if !outcome.failed.isEmpty { store.alertMessage = outcome.failureText }
        }
    }

    // MARK: 操作

    private func replacePin(_ old: String, with new: String) {
        if let i = store.pinnedFolders.firstIndex(of: old) {
            store.pinnedFolders[i] = new
        }
        model.movePath(old, to: new)
        // 自动整理规则里用到这个文件夹（监视或目标）的也跟着改，不然会在旧位置重新冒出一个同名文件夹。
        store.organizer.retarget(from: old, to: new)
        if store.selection == .pinned(old) { store.selection = .pinned(new) }
    }

    private func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != summary.name else { return }
        let src = URL(fileURLWithPath: summary.path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: src, to: dst)
            replacePin(summary.path, with: dst.path)
            FileUndoCenter.shared.registerPaths([FileUndoLogic.PathPair(from: src.path, to: dst.path)],
                                                name: String(localized: "重命名"),
                                                toast: String(localized: "已重命名为「\(trimmed)」"))
        } catch {
            store.alertMessage = error.localizedDescription
        }
    }

    private func moveFolder() {
        // 桌面、下载、个人文件夹这些 macOS 需要的文件夹不能搬走（访达也不让）。
        if store.refuseProtected([summary.path]) { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "移到这里")
        panel.message = String(localized: "把「\(summary.name)」移到哪个文件夹？")
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let src = URL(fileURLWithPath: summary.path)
        let dst = target.appendingPathComponent(src.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: src, to: dst)
            replacePin(summary.path, with: dst.path)
            FileUndoCenter.shared.registerPaths([FileUndoLogic.PathPair(from: src.path, to: dst.path)],
                                                name: String(localized: "移动"),
                                                toast: String(localized: "已移到「\(target.lastPathComponent)」"))
        } catch {
            store.alertMessage = error.localizedDescription
        }
    }

    private func openFolder() {
        store.openFolder(URL(fileURLWithPath: summary.path, isDirectory: true))
    }

    private func startRename() {
        if store.refuseProtected([summary.path]) { return }
        newName = summary.name
        renaming = true
    }

    /// 把文件拖到卡片上：移进这个文件夹（按住 ⌥ 拷贝）。走和「移动到…」同一条路：同名自动加编号、不覆盖，
    /// 移动记进「清理记录」，⌘Z / 小提示上的「撤销」可以放回。
    private func moveIn(_ urls: [URL], copy: Bool) {
        store.transferDropped(urls, into: URL(fileURLWithPath: summary.path, isDirectory: true), copy: copy)
    }
}

// MARK: - 小部件

/// 访达里的文件夹图标，按卡片大小和屏幕倍率取够大的图（大卡片不糊）。revision 变了重新读（上色、刷新）。
private struct SystemFolderIcon: View {
    let path: String
    let side: CGFloat
    let revision: Int
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    private struct Key: Equatable {
        let path: String
        let pixels: Int
        let revision: Int
    }

    /// 取图的像素边长：向上取到 128 的倍数，拖滑块时不用每一档都重画。
    private var pixels: Int {
        let need = Int((side * max(scale, 1)).rounded(.up))
        return min(max((need + 127) / 128 * 128, 128), 1024)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .task(id: Key(path: path, pixels: pixels, revision: revision)) {
            image = await Self.render(path, pixels: pixels)
        }
    }

    @MainActor
    static func render(_ path: String, pixels: Int) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        // 图标的 size 默认是 32pt，先放大，取图时才会选上最大的那张（512@2x / 1024）。
        icon.size = NSSize(width: pixels, height: pixels)
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// 文稿纸：真实页面缩略图（没取到时画几行占位）。投影由外面加。
struct PaperChip: View {
    let url: URL?
    var small = false
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            DogEar().fill(.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .clipShape(DogEar())
                    .opacity(0.95)
            } else {
                VStack(alignment: .leading, spacing: small ? 3 : 6) {
                    ForEach(0..<4, id: \.self) { k in
                        Capsule().fill(Color(red: 0.80, green: 0.80, blue: 0.87))
                            .frame(height: small ? 2.5 : 4)
                            .padding(.trailing, (k % 2 == 0 ? 14 : 24) * (small ? 0.5 : 1))
                    }
                }
                .padding(.leading, small ? 6 : 12)
                .padding(.top, small ? 9 : 16)
            }
            DogEarFold().fill(Color(red: 0.89, green: 0.89, blue: 0.93))
        }
        .task(id: url) {
            if let url { image = await ThumbnailService.shared.thumbnail(for: url, size: 128) }
        }
    }
}

private struct DogEar: Shape {
    func path(in r: CGRect) -> Path {
        let f = min(r.width, r.height) * 0.22
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 5, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + f))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 5))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 5, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 5, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 5), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 5))
        p.addQuadCurve(to: CGPoint(x: r.minX + 5, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct DogEarFold: Shape {
    func path(in r: CGRect) -> Path {
        let f = min(r.width, r.height) * 0.22
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - f, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + f))
        p.closeSubpath()
        return p
    }
}

/// 后片：左上角是文件夹标签。参数默认值是以前的样子；拾掇风格玻璃卡片见 GlassFolderMetrics.backShape。
struct BackPanel: Shape {
    var rad: CGFloat = 16
    var stepRatio: CGFloat = 0.11
    var splitRatio: CGFloat = 0.40
    var slope: CGFloat = 26

    func path(in r: CGRect) -> Path {
        let step = r.height * stepRatio
        let split = r.width * splitRatio
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + split - slope / 2, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + split + slope / 2, y: r.minY + step),
                   control1: CGPoint(x: r.minX + split, y: r.minY),
                   control2: CGPoint(x: r.minX + split, y: r.minY + step))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY + step))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + step + rad), control: CGPoint(x: r.maxX, y: r.minY + step))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 前片：右侧微微凸起，四角圆润。continuous = 连续圆角（三次曲线，近似 .continuous），玻璃卡片用。
struct FrontPanel: Shape {
    var rad: CGFloat = 20
    var stepRatio: CGFloat = 0.13
    var splitRatio: CGFloat = 0.42
    var slope: CGFloat = 30
    var continuous = false

    func path(in r: CGRect) -> Path {
        let step = r.height * stepRatio
        let split = r.width * splitRatio
        let k = continuous ? rad * 0.55 : 0
        /// 一个圆角：continuous 用三次曲线，否则二次曲线（以前的样子）。
        func corner(_ p: inout Path, to end: CGPoint, corner c: CGPoint, from start: CGPoint) {
            if continuous {
                let c1 = CGPoint(x: start.x + (c.x - start.x) * (k / rad), y: start.y + (c.y - start.y) * (k / rad))
                let c2 = CGPoint(x: end.x + (c.x - end.x) * (k / rad), y: end.y + (c.y - end.y) * (k / rad))
                p.addCurve(to: end, control1: c1, control2: c2)
            } else {
                p.addQuadCurve(to: end, control: c)
            }
        }
        var p = Path()
        let a = CGPoint(x: r.minX, y: r.minY + step + rad)
        p.move(to: a)
        corner(&p, to: CGPoint(x: r.minX + rad, y: r.minY + step), corner: CGPoint(x: r.minX, y: r.minY + step), from: a)
        p.addLine(to: CGPoint(x: r.minX + split - slope / 2, y: r.minY + step))
        p.addCurve(to: CGPoint(x: r.minX + split + slope / 2, y: r.minY),
                   control1: CGPoint(x: r.minX + split, y: r.minY + step),
                   control2: CGPoint(x: r.minX + split, y: r.minY))
        let b = CGPoint(x: r.maxX - rad, y: r.minY)
        p.addLine(to: b)
        corner(&p, to: CGPoint(x: r.maxX, y: r.minY + rad), corner: CGPoint(x: r.maxX, y: r.minY), from: b)
        let c = CGPoint(x: r.maxX, y: r.maxY - rad)
        p.addLine(to: c)
        corner(&p, to: CGPoint(x: r.maxX - rad, y: r.maxY), corner: CGPoint(x: r.maxX, y: r.maxY), from: c)
        let d = CGPoint(x: r.minX + rad, y: r.maxY)
        p.addLine(to: d)
        corner(&p, to: CGPoint(x: r.minX, y: r.maxY - rad), corner: CGPoint(x: r.minX, y: r.maxY), from: d)
        p.closeSubpath()
        return p
    }
}
