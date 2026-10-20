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

    static func load(_ path: String) -> FolderSummary {
        let url = URL(fileURLWithPath: path)
        var s = FolderSummary(path: path, name: FileManager.default.displayName(atPath: path))
        s.label = (try? url.resourceValues(forKeys: [.labelNumberKey]).labelNumber) ?? 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return s }

        var images: [(URL, Date)] = []
        var docs: [(URL, Date)] = []
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
            } else if type.conforms(to: .font) || ["sketch", "fig", "psd", "ai", "xd", "ttf", "otf"].contains(child.pathExtension.lowercased()) {
                design += 1
            } else if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
                        || type.conforms(to: .spreadsheet) || ["doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "md"].contains(child.pathExtension.lowercased()) {
                docs.append((child, date))
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
        switch s.look {
        case .photos: s.previews = images.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        case .papers, .cloud: s.previews = docs.sorted { $0.1 > $1.1 }.prefix(2).map(\.0)
        default: break
        }
        return s
    }
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

    func reload(_ paths: [String]) {
        Task.detached(priority: .userInitiated) {
            var result: [String: FolderSummary] = [:]
            for path in paths { result[path] = FolderSummary.load(path) }
            await MainActor.run {
                self.summaries = result
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
    var selected = false
    /// 墙上按回车时设成这张卡片的路径：弹出重命名。
    @Binding var renamingPath: String?
    var onSelect: () -> Void = {}
    /// 别的卡片拖到这张上面：排到它前面。
    var onDropTile: (String) -> Void = { _ in }

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var renaming = false
    @State private var newName = ""

    private var height: CGFloat { width * 0.80 }
    /// 小卡片上字也小一点。
    private var nameSize: CGFloat { width < 120 ? 12 : 14 }

    /// 卡片本身（拆开写：整串修饰符太长，编译器类型检查会超时）。
    private var face: some View {
        VStack(spacing: 6) {
            folder
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
        guard let date = summary.updated, date > .distantPast else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return String(localized: "\(f.localizedString(for: min(date, Date().addingTimeInterval(-1)), relativeTo: Date()))更新")
    }

    // MARK: 文件夹本体

    private var folder: some View {
        let light = tint.isLight
        let back = Color(nsColor: tint.mixed(.black, light ? 0.10 : 0.16))
        let backTop = Color(nsColor: tint.mixed(.white, 0.08).mixed(.black, light ? 0.06 : 0.12))
        let frontTop = Color(nsColor: tint.mixed(.white, light ? 0.55 : 0.42))
        let front = Color(nsColor: tint)
        let ink = light ? Color.black.opacity(0.62) : Color.white
        return ZStack(alignment: .top) {
            // 同色光晕
            RoundedRectangle(cornerRadius: 20)
                .fill(front.opacity(0.55))
                .frame(width: width - 50, height: height * 0.30)
                .blur(radius: 18)
                .offset(y: height * 0.78)

            BackPanel()
                .fill(LinearGradient(colors: [backTop, back], startPoint: .top, endPoint: .bottom))
                .frame(width: width - 12, height: height * 0.86 - 26)
                .offset(y: height * 0.14)

            contents
                .offset(y: hovering ? -10 : 0)

            ZStack {
                FrontPanel().fill(.ultraThinMaterial)
                FrontPanel().fill(LinearGradient(colors: [frontTop.opacity(0.86), front.opacity(0.97)], startPoint: .top, endPoint: .bottom))
                FrontPanel().stroke(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                VStack(spacing: 6) {
                    Spacer()
                    ForEach(0..<2, id: \.self) { _ in
                        Rectangle().fill(.white.opacity(0.32)).frame(height: 1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                frontGlyph(light: light)
                overlays(ink: ink, light: light)
            }
            .frame(width: width, height: height * 0.54)
            .shadow(color: .black.opacity(0.10), radius: 6, y: 4)
            .offset(y: height * 0.46)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    @ViewBuilder
    private var contents: some View {
        switch summary.look {
        case .photos:
            let slots: [(CGFloat, Double)] = [(-0.23, -9), (0.23, 9), (0, -1)]
            ZStack {
                ForEach(Array(summary.previews.prefix(3).enumerated().reversed()), id: \.offset) { i, url in
                    let slot = slots[i == 0 ? 2 : i - 1]
                    PhotoChip(url: url, size: CGSize(width: width * 0.46, height: width * 0.38))
                        .rotationEffect(.degrees(slot.1 * (hovering ? 1.4 : 1)))
                        .offset(x: width * slot.0 * (hovering ? 1.25 : 1), y: slot.0 == 0 ? -6 : 0)
                }
            }
            .offset(y: height * 0.10)
        case .papers:
            ZStack {
                ForEach(0..<max(1, min(2, summary.previews.count)), id: \.self) { i in
                    PaperChip(url: summary.previews.indices.contains(i) ? summary.previews[i] : nil)
                        .frame(width: width * 0.36, height: width * 0.40)
                        .rotationEffect(.degrees((i == 0 ? -6.0 : 5.0) * (hovering ? 1.5 : 1)))
                        .offset(x: (i == 0 ? -0.13 : 0.13) * width * (hovering ? 1.3 : 1))
                }
            }
            .offset(y: height * 0.10)
        case .tiles:
            ZStack {
                tileChip(Color(red: 0.98, green: 0.77, blue: 0.24), nil, size: width * 0.26)
                    .rotationEffect(.degrees(-12)).offset(x: -width * 0.26 * (hovering ? 1.2 : 1), y: 6)
                tileChip(Color(red: 0.93, green: 0.31, blue: 0.39), nil, size: width * 0.24)
                    .rotationEffect(.degrees(10)).offset(x: width * 0.24 * (hovering ? 1.2 : 1), y: 8)
                tileChip(Color(red: 0.98, green: 0.93, blue: 0.89), "Aa", size: width * 0.32)
            }
            .offset(y: height * 0.08)
        case .cloud:
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.985))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(0..<3, id: \.self) { k in
                            Capsule().fill(Color(red: 0.84, green: 0.86, blue: 0.91))
                                .frame(width: width * (0.55 - CGFloat(k) * 0.12), height: 5)
                        }
                    }
                    .padding(14)
                }
                .frame(width: width * 0.78, height: height * 0.5)
                .offset(y: height * 0.20)
        case .archive, .plain:
            EmptyView()
        }
    }

    private func tileChip(_ color: Color, _ label: String?, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8).fill(color).padding(3)
                    .overlay {
                        if let label {
                            Text(label).font(.system(size: size * 0.42, weight: .medium))
                                .foregroundStyle(Color(red: 0.55, green: 0.27, blue: 0.16))
                        }
                    }
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
    }

    @ViewBuilder
    private func frontGlyph(light: Bool) -> some View {
        let color = Color.white.opacity(light ? 0.95 : 0.55)
        switch summary.look {
        case .cloud:
            Image(systemName: "cloud")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color(red: 0.42, green: 0.60, blue: 0.82))
        case .tiles:
            Text("a")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        case .archive:
            HStack {
                VStack(spacing: 3) {
                    Capsule()
                        .fill(Color(white: 0.90))
                        .overlay(Capsule().strokeBorder(Color(white: 0.72)))
                        .overlay(Circle().fill(Color(white: 0.45)).frame(width: 5, height: 5).offset(y: -5))
                        .frame(width: 13, height: 26)
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.72)).frame(width: 12, height: 2.5)
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 16)
                Spacer()
            }
            .frame(maxHeight: .infinity, alignment: .top)
        default:
            EmptyView()
        }
    }

    private func overlays(ink: Color, light: Bool) -> some View {
        ZStack {
            if hovering {
                HStack(spacing: 4) {
                    actionButton("pencil", help: String(localized: "重命名")) { startRename() }
                    actionButton("folder", help: String(localized: "移动到…")) { moveFolder() }
                    actionButton("paintpalette", help: String(localized: "自定义颜色…")) { model.openColorPanel(for: summary) }
                    actionButton("minus.circle", help: String(localized: "从文件夹墙移除"), tint: .red) { store.unpin(summary.path) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 16)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            HStack {
                if reminderCount > 0 {
                    Label("\(reminderCount)", systemImage: "alarm")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(light ? 0.9 : 0.22)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.45)))
                }
                Spacer()
                if let badge, !hovering {
                    Text(badge)
                        .font(.system(size: 11, weight: summary.look == .archive ? .bold : .medium))
                        .foregroundStyle(Color.black.opacity(0.68))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.88)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.5)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
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
                colorMenu
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

private struct PhotoChip: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(white: 0.92)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size.width - 6, height: size.height - 6)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
        .task(id: url) { image = await ThumbnailService.shared.thumbnail(for: url, size: 256) }
    }
}

private struct PaperChip: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            DogEar().fill(.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .clipShape(DogEar())
                    .opacity(0.95)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<4, id: \.self) { k in
                        Capsule().fill(Color(red: 0.80, green: 0.80, blue: 0.87))
                            .frame(height: 4)
                            .padding(.trailing, k % 2 == 0 ? 14 : 24)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 16)
            }
            DogEarFold().fill(Color(red: 0.89, green: 0.89, blue: 0.93))
        }
        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
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

/// 后片：左上角是文件夹标签。
struct BackPanel: Shape {
    func path(in r: CGRect) -> Path {
        let rad: CGFloat = 16
        let step = r.height * 0.11
        let split = r.width * 0.40
        let slope: CGFloat = 26
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

/// 前片：右侧微微凸起，四角圆润。
struct FrontPanel: Shape {
    func path(in r: CGRect) -> Path {
        let rad: CGFloat = 20
        let step = r.height * 0.13
        let split = r.width * 0.42
        let slope: CGFloat = 30
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + step + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY + step), control: CGPoint(x: r.minX, y: r.minY + step))
        p.addLine(to: CGPoint(x: r.minX + split - slope / 2, y: r.minY + step))
        p.addCurve(to: CGPoint(x: r.minX + split + slope / 2, y: r.minY),
                   control1: CGPoint(x: r.minX + split, y: r.minY + step),
                   control2: CGPoint(x: r.minX + split, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
