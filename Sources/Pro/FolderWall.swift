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

enum FolderPalette {
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
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.78
    }
}

// MARK: - 页面

struct FolderWallView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var model = FolderWallModel.shared
    @ObservedObject private var reminders = ReminderStore.shared
    @State private var query = ""
    @State private var sort: Sort = .recent
    @FocusState private var searchFocused: Bool

    enum Sort: String, CaseIterable, Identifiable {
        case recent, name, size
        var id: Self { self }
        var title: String {
            switch self {
            case .recent: return String(localized: "最近")
            case .name: return String(localized: "名称")
            case .size: return String(localized: "大小")
            }
        }
        var symbol: String {
            switch self {
            case .recent: return "clock"
            case .name: return "textformat"
            case .size: return "internaldrive"
            }
        }
    }

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
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if store.pinnedFolders.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 228, maximum: 260), spacing: 20)], spacing: 30) {
                        ForEach(folders, id: \.path) { s in
                            FolderCard(summary: s,
                                       tint: model.tint(for: s),
                                       reminderCount: reminders.reminders.filter { $0.path.hasPrefix(s.path + "/") }.count)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 34)
                    .padding(.bottom, 30)
                }
            }
        }
        .onAppear { model.reload(store.pinnedFolders) }
        .onChange(of: store.pinnedFolders) { model.reload(store.pinnedFolders) }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("/", modifiers: [])
                .disabled(searchFocused)
                .opacity(0)
        }
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
                Button {
                    store.choosePinnedFolder()
                } label: {
                    Label("固定文件夹", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
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

                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
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
            Text("还没有固定文件夹")
                .font(.title3.weight(.semibold))
            Text("固定常用的文件夹，这里会变成一面卡片墙，一眼看到里面有什么。")
                .foregroundStyle(.secondary)
            Button("固定文件夹…") { store.choosePinnedFolder() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 卡片

struct FolderCard: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var model = FolderWallModel.shared
    let summary: FolderSummary
    let tint: NSColor
    let reminderCount: Int

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var renaming = false
    @State private var newName = ""

    private let width: CGFloat = 196
    private var height: CGFloat { width * 0.80 }

    var body: some View {
        VStack(spacing: 6) {
            folder
                .frame(width: width, height: height)
                .scaleEffect(dropTargeted ? 1.05 : 1)
            Text(summary.name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .padding(.top, 10)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(hovering || dropTargeted ? 0.055 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onHover { h in withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { hovering = h } }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dropTargeted)
        .onTapGesture { store.selection = .pinned(summary.path) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { urls in moveIn(urls) }
        }
        .help(summary.path)
        .contextMenu { menu }
        .alert("重命名文件夹", isPresented: $renaming) {
            TextField("名称", text: $newName)
            Button("重命名") { rename(to: newName) }
            Button("取消", role: .cancel) {}
        }
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
        return String(localized: "\(f.localizedString(for: date, relativeTo: Date()))更新")
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
                    actionButton("pencil", help: String(localized: "重命名")) {
                        newName = summary.name
                        renaming = true
                    }
                    actionButton("folder", help: String(localized: "移动到…")) { moveFolder() }
                    actionButton("pin.slash", help: String(localized: "取消固定"), tint: .red) { store.unpin(summary.path) }
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
                        .foregroundStyle(summary.look == .archive ? Color.black.opacity(0.72) : ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(summary.look == .archive || light ? 0.92 : 0.24)))
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

    @ViewBuilder
    private var menu: some View {
        Button("打开") { store.selection = .pinned(summary.path) }
        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.path)])
        }
        Divider()
        Button("重命名…") {
            newName = summary.name
            renaming = true
        }
        Button("移动到…") { moveFolder() }
        Menu("颜色") {
            Button("自动") { model.manualColors[summary.path] = nil }
            Divider()
            ForEach(FolderPalette.colors.indices, id: \.self) { i in
                Button(FolderPalette.colors[i].0) { model.manualColors[summary.path] = i }
            }
        }
        Divider()
        Button("取消固定") { store.unpin(summary.path) }
    }

    // MARK: 操作

    private func replacePin(_ old: String, with new: String) {
        if let i = store.pinnedFolders.firstIndex(of: old) {
            store.pinnedFolders[i] = new
        }
        if let color = model.manualColors.removeValue(forKey: old) { model.manualColors[new] = color }
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
            store.showToast(String(localized: "已重命名为「\(trimmed)」"))
        } catch {
            store.alertMessage = error.localizedDescription
        }
    }

    private func moveFolder() {
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
            store.showToast(String(localized: "已移到「\(target.lastPathComponent)」"))
        } catch {
            store.alertMessage = error.localizedDescription
        }
    }

    /// 把文件拖到卡片上：移进这个文件夹（重名时自动加编号）。
    private func moveIn(_ urls: [URL]) {
        let folder = URL(fileURLWithPath: summary.path)
        var moved = 0
        for url in urls where url.deletingLastPathComponent().standardizedFileURL.path != folder.standardizedFileURL.path {
            guard url.standardizedFileURL.path != folder.standardizedFileURL.path,
                  !folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/") else { continue }
            var dst = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            while FileManager.default.fileExists(atPath: dst.path) {
                dst = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            if (try? FileManager.default.moveItem(at: url, to: dst)) != nil { moved += 1 }
        }
        if moved > 0 {
            store.showToast(String(localized: "已移到「\(summary.name)」：\(moved) 个"))
            model.reload(store.pinnedFolders)
        }
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
