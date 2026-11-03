import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 字体库：网格 / 列表两种看法，右边是选中字体的详情面板

/// 字体库标签：网格（大样张，字号、字距、颜色、统一视觉大小、辅助线）或列表（可排序的表格），
/// 选中一款时右边出详情面板（正文 · 字符 · 特性 · 可变 · 信息）。
struct FontLibraryTab: View {
    @ObservedObject private var library = FontLibrary.shared
    @ObservedObject private var extras = FontExtraInfoStore.shared
    let families: [FontFamily]
    let layout: FontLibraryLayout
    @State private var selection: Set<String> = []
    /// 新建字体集要加进去的字体（右键时的整批）。
    @State private var newSetTargets: [FontFamily]?
    @State private var newSetName = ""
    /// ⇧ 连选的起点（上次点的那款）。
    @State private var anchor: String?
    /// 移到废纸篓前的确认（⌘⌫ / 右键）。
    @State private var trashPaths: [String] = []
    @State private var confirmTrash = false
    /// 字体文件拖到窗口上方。
    @State private var dropTargeted = false
    @StateObject private var marquee = FontMarqueeModel()
    @State private var cardFrames = FontCardFrames()
    @State private var viewport: CGSize = .zero
    /// 网格 + 详情面板一共多宽。
    @State private var contentWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool
    /// Option + 双指缩放开始时的字距。
    @State private var magnifyBase: Double? = nil

    // 网格预览的设置（下次打开还是这样）。
    @AppStorage("fonts.sampleText") private var sample = FontCoverage.defaultSample
    @AppStorage("fonts.sampleSize") private var size = 48.0
    @AppStorage("fonts.tracking") private var tracking = 0.0
    @AppStorage("fonts.previewColors") private var colorsRaw = FontPreviewColors.blackOnWhite.rawValue
    @AppStorage("fonts.unifySize") private var unify = false
    @AppStorage("fonts.guides") private var guides = false

    // 列表的排序和显示哪些列。
    @AppStorage("fonts.listSort") private var listSortRaw = FontListSort.default.rawValue
    @AppStorage("fonts.listColumns") private var columnsData = Data()
    @State private var columnCustomization = TableColumnCustomization<FontListRow>()
    @State private var columnsLoaded = false

    private var selectedFamilies: [FontFamily] { families.filter { selection.contains($0.id) } }
    private var selectedUserPaths: [String] {
        selectedFamilies.flatMap { family in family.faces.filter { $0.location == .user }.map(\.path) }.uniqued()
    }
    private var selectedStoredIDs: [UUID] {
        selectedFamilies.flatMap { family in family.faces.compactMap(\.manifestID) }.uniqued()
    }
    /// 只选了一款时右边显示它的详情。
    private var detailFamily: FontFamily? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return families.first { $0.id == id } ?? library.families.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if layout == .grid {
                FontPreviewToolbar(sample: $sample, size: $size, tracking: $tracking, colorsRaw: $colorsRaw,
                                   unify: $unify, guides: $guides)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Divider()
            }
            HStack(spacing: 0) {
                Group {
                    if families.isEmpty {
                        Text("没有符合条件的字体")
                            .foregroundStyle(.secondary)
                    } else if layout == .grid {
                        grid
                    } else {
                        table
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let family = detailFamily {
                    Divider()
                    FontDetailPanel(family: family) { selection = [] }
                        .id(family.id)
                        // 窄窗口时详情面板跟着变窄（最多 440，最多占一半），不把网格挤出窗口。
                        .frame(width: FontLayoutLogic.detailWidth(total: contentWidth))
                }
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { contentWidth = proxy.size.width }
            })
            Divider()
            bottomBar
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                    Label("松手安装字体", systemImage: "square.and.arrow.down")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        // 把字体文件（或装着字体的文件夹）拖进来：装进 ~/Library/Fonts，可撤销；已经装着的跳过。
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { urls in
                let list = urls
                Task { await library.installDropped(list) }
            }
        }
        // ⌘⌫（「文件」菜单）：把选中的用户字体移到废纸篓，先确认。
        .trashContext(ids: Set(selectedUserPaths), items: {
            selectedUserPaths.compactMap { FileItem(url: URL(fileURLWithPath: $0)) }
        }, perform: { items in
            requestTrash(items.map(\.path))
        })
        .confirmationDialog("把 \(trashPaths.count) 个字体文件移到废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                let paths = trashPaths
                trashPaths = []
                selection = []
                library.trash(paths: paths)
            }
            Button("取消", role: .cancel) { trashPaths = [] }
        } message: {
            Text("只动「用户字体」（~/Library/Fonts 里的），系统字体不会动。推荐用「停用」：不删文件，以后还能一键启用。移到废纸篓后 30 天内可以在「清理记录」里放回。")
        }
        .task(id: layout == .list ? families.count : -1) {
            // 列表要厂商、字数这些另外读的信息：后台读，读到一批显示一批。
            if layout == .list { extras.load(families.compactMap(\.representative)) }
        }
        .alert("新建字体集", isPresented: Binding(get: { newSetTargets != nil }, set: { if !$0 { newSetTargets = nil } })) {
            TextField("名字，比如「客户A 品牌」", text: $newSetName)
            Button("新建") {
                if let targets = newSetTargets, let set = library.createSet(name: newSetName) {
                    library.add(targets, to: set.id)
                }
                newSetTargets = nil
                newSetName = ""
            }
            Button("取消", role: .cancel) {
                newSetTargets = nil
                newSetName = ""
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // 说明文字最先让位：窗口窄时截断，按钮不会被挤出窗口。
            Label("系统字体只显示、不会动；/Library/Fonts 里的要管理员权限，拾掇也不改。停用是移进拾掇的字体仓库，不是删除。",
                  systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            AdaptiveRow(spacing: 10) {
                if !selection.isEmpty {
                    Text("已选 \(selection.count) 款")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if selection.count >= 2 {
                    Button("对比所选（\(min(selection.count, FontCompareLogic.maxCount))）") {
                        library.addToCompare(selectedFamilies)
                        library.tab = .compare
                    }
                }
                if !selectedStoredIDs.isEmpty {
                    Button("启用所选") {
                        let ids = selectedStoredIDs
                        Task { await library.enable(entryIDs: ids) }
                    }
                }
                Button("停用所选（\(selectedUserPaths.count)）") {
                    disableSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedUserPaths.isEmpty || library.busy != nil)
                .help("只停用「用户字体」（~/Library/Fonts 里的）")
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 网格

    private static let gridSpace = "fontGrid"

    private var grid: some View {
        let palette = FontPreviewPalette.colors(FontPreviewColors(rawValue: colorsRaw) ?? .blackOnWhite)
        return ScrollView {
            // 列宽不超过实际能用的宽度：窗口再窄也至少一列、不会被裁掉。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: FontLayoutLogic.gridMinimum(size: size, available: viewport.width - 40)),
                                         spacing: 14)], spacing: 14) {
                ForEach(families) { family in
                    FontGridCard(family: family, mark: library.mark(for: family), status: library.commercialStatus(family),
                                 sample: sample, size: size, tracking: tracking, palette: palette,
                                 unify: unify, guides: guides, selected: selection.contains(family.id))
                        .contentShape(Rectangle())
                        .onTapGesture { tap(family) }
                        .stableContextMenu { menu(for: family) }
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: FontCardFramesKey.self,
                                                   value: [family.id: proxy.frame(in: .named(Self.gridSpace))])
                        })
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: viewport.height, alignment: .top)
            // 在空白处拖动：框选（⌘ 拖动在原来的选中上反选）；只点一下空白处取消选中。
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture)
            )
            .overlay(alignment: .topLeading) { FontMarqueeOverlay(model: marquee) }
            .coordinateSpace(name: Self.gridSpace)
            // 合并：LazyVGrid 回收了滚出屏幕的卡片，位置还留着，框选时照样算。
            .onPreferenceChange(FontCardFramesKey.self) { frames in cardFrames.frames.merge(frames) { $1 } }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { viewport = proxy.size }
                .onChange(of: proxy.size) { viewport = proxy.size }
        })
        .onChange(of: viewport.width) { cardFrames.frames = [:] }
        .onChange(of: size) { cardFrames.frames = [:] }
        .onChange(of: families.count) { cardFrames.frames = [:] }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll() }
        .onKeyPress(.escape) {
            if let restored = marquee.cancel() {
                selection = restored
                return .handled
            }
            guard !selection.isEmpty else { return .ignored }
            selection = []
            return .handled
        }
        // ⌫：停用所选（和「停用所选」一样）。⌘⌫ 由「文件」菜单处理（移到废纸篓）。
        .onKeyPress(keys: [.delete]) { press in
            guard press.modifiers.subtracting([.numericPad, .function]).isEmpty else { return .ignored }
            disableSelected()
            return .handled
        }
        // 按住 Option 双指缩放：调字距（不按 Option 时不管，留给系统）。
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard NSEvent.modifierFlags.contains(.option) else { return }
                    let base = magnifyBase ?? tracking
                    magnifyBase = base
                    tracking = FontTracking.afterMagnify(base: base, magnification: Double(value.magnification))
                }
                .onEnded { _ in magnifyBase = nil }
        )
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if !marquee.active {
                    gridFocused = true
                    marquee.begin(at: value.startLocation, flags: NSEvent.modifierFlags, base: selection,
                                  ids: Set(families.map(\.id)))
                }
                if let next = marquee.update(to: value.location, frames: cardFrames.frames), next != selection {
                    selection = next
                }
            }
            .onEnded { value in
                let result = marquee.end(at: value.location, frames: cardFrames.frames)
                if result.wasClick {
                    selection = []
                } else if let next = result.selection, next != selection {
                    selection = next
                }
                // 下次 ⇧ 连选从框到的第一款开始。
                if let first = families.first(where: { selection.contains($0.id) }) { anchor = first.id }
            }
    }

    private func tap(_ family: FontFamily) {
        gridFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            // ⇧ 点按：从上次点的那款连选到这款（按现在的排列顺序）；⇧⌘ 加到原来的选中上。
            let range = FontSelectionLogic.range(families.map(\.id), anchor: anchor, target: family.id)
            selection = flags.contains(.command) ? selection.union(range) : Set(range)
            if anchor == nil { anchor = family.id }
            return
        }
        anchor = family.id
        if flags.contains(.command) {
            if selection.contains(family.id) { selection.remove(family.id) } else { selection.insert(family.id) }
        } else {
            selection = selection == [family.id] ? [] : [family.id]
        }
    }

    /// ⌘A：选中现在显示的所有字体。
    private func selectAll() {
        selection = Set(families.map(\.id))
    }

    /// ⌫ / 「停用所选」：只停用用户字体（系统、/Library/Fonts 的不动）。
    private func disableSelected() {
        let paths = selectedUserPaths
        guard !paths.isEmpty, library.busy == nil else { return }
        Task { await library.disable(paths: paths) }
    }

    /// 移到废纸篓前先确认（只收 ~/Library/Fonts 里的）。
    private func requestTrash(_ paths: [String]) {
        let home = FontLibrary.home
        let allowed = paths.filter { FontPathRules.canDisable($0, home: home) }
        guard !allowed.isEmpty else {
            library.trash(paths: paths) // 只是解释为什么不能动
            return
        }
        trashPaths = allowed
        confirmTrash = true
    }

    // MARK: 列表

    private var listSort: FontListSort { FontListSort(rawValue: listSortRaw) ?? .default }

    private var rows: [FontListRow] {
        let list = families.map { family in
            FontListLogic.row(family, extra: extras.info(for: family.representative), license: library.commercialStatus(family).title)
        }
        return FontListLogic.sorted(list, by: listSort)
    }

    /// 点表头换排序时存下来（下次打开还是这个排序）。
    private var sortBinding: Binding<[KeyPathComparator<FontListRow>]> {
        Binding(
            get: { [FontListLogic.comparator(listSort)] },
            set: { listSortRaw = FontListLogic.sort(from: $0, current: listSort).rawValue }
        )
    }

    private var table: some View {
        let byID = Dictionary(families.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Table(of: FontListRow.self, selection: $selection, sortOrder: sortBinding, columnCustomization: $columnCustomization) {
            Group {
                TableColumn("名称", value: \FontListRow.name) { row in
                    cell(row, byID) { Text(verbatim: row.name).lineLimit(1) }
                }
                .width(min: 140, ideal: 200)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)
                TableColumn("样式", value: \FontListRow.styleCount) { row in
                    cell(row, byID) { Text(verbatim: "\(row.styleCount)").monospacedDigit() }
                }
                .width(min: 36, ideal: 48)
                .customizationID("styles")
                TableColumn("格式", value: \FontListRow.format) { row in
                    cell(row, byID) { Text(verbatim: row.format).lineLimit(1) }
                }
                .width(min: 40, ideal: 64)
                .customizationID("format")
                TableColumn("版本", value: \FontListRow.versionKey) { row in
                    cell(row, byID) { Text(verbatim: row.version).lineLimit(1) }
                }
                .width(min: 50, ideal: 70)
                .customizationID("version")
                TableColumn("厂商", value: \FontListRow.manufacturer) { row in
                    cell(row, byID) { Text(verbatim: row.manufacturer).lineLimit(1) }
                }
                .width(min: 60, ideal: 110)
                .customizationID("manufacturer")
                TableColumn("字数", value: \FontListRow.glyphCount) { row in
                    cell(row, byID) { Text(verbatim: row.glyphCount > 0 ? row.glyphCount.formatted() : "—").monospacedDigit() }
                }
                .width(min: 50, ideal: 70)
                .customizationID("glyphs")
            }
            Group {
                TableColumn("添加日期", value: \FontListRow.added) { row in
                    cell(row, byID) {
                        Text(verbatim: row.added == .distantPast ? "—" : row.added.formatted(date: .numeric, time: .omitted))
                            .lineLimit(1)
                    }
                }
                .width(min: 70, ideal: 90)
                .customizationID("added")
                TableColumn("设计师", value: \FontListRow.designer) { row in
                    cell(row, byID) { Text(verbatim: row.designer).lineLimit(1) }
                }
                .width(min: 60, ideal: 110)
                .customizationID("designer")
                .defaultVisibility(.hidden)
                TableColumn("路径", value: \FontListRow.path) { row in
                    cell(row, byID) {
                        Text(verbatim: row.path).lineLimit(1).truncationMode(.middle).help(row.path)
                    }
                }
                .width(min: 80, ideal: 200)
                .customizationID("path")
                .defaultVisibility(.hidden)
                TableColumn("大小", value: \FontListRow.bytes) { row in
                    cell(row, byID) { Text(verbatim: row.bytes.byteText).monospacedDigit() }
                }
                .width(min: 50, ideal: 70)
                .customizationID("size")
                .defaultVisibility(.hidden)
                TableColumn("授权", value: \FontListRow.license) { row in
                    cell(row, byID) { Text(verbatim: row.license).lineLimit(1) }
                }
                .width(min: 50, ideal: 70)
                .customizationID("license")
                .defaultVisibility(.hidden)
            }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
            }
        }
        .onDeleteCommand { disableSelected() }
        .onExitCommand { selection = [] }
        .onAppear(perform: loadColumns)
        .onChange(of: columnCustomization) { _, value in
            guard columnsLoaded, let data = try? JSONEncoder().encode(value) else { return }
            columnsData = data
        }
    }

    private func loadColumns() {
        if !columnsData.isEmpty, let saved = try? JSONDecoder().decode(TableColumnCustomization<FontListRow>.self, from: columnsData) {
            columnCustomization = saved
        }
        columnsLoaded = true
    }

    /// 列表单元格：撑满列宽（点在空白处也算这一行），挂上右键菜单快照（菜单开着时内容不再变）。
    private func cell<Content: View>(_ row: FontListRow, _ byID: [String: FontFamily],
                                     @ViewBuilder _ content: () -> Content) -> some View {
        let family = byID[row.id]
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .stableContextMenu {
                if let family { menu(for: family) }
            }
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func menu(for family: FontFamily) -> some View {
        let targets = selection.contains(family.id) ? selectedFamilies : [family]
        let userPaths = targets.flatMap { $0.faces.filter { $0.location == .user }.map(\.path) }.uniqued()
        let storedIDs = targets.flatMap { $0.faces.compactMap(\.manifestID) }.uniqued()
        if !userPaths.isEmpty {
            Button("停用") { Task { await library.disable(paths: userPaths) } }
        }
        if !storedIDs.isEmpty {
            Button("启用") { Task { await library.enable(entryIDs: storedIDs) } }
        }
        if !userPaths.isEmpty {
            Button("移到废纸篓…") { requestTrash(userPaths) }
        }
        Button("加入对比") { library.addToCompare(targets) }
        if targets.count >= 2 {
            Button("对比这 \(min(targets.count, FontCompareLogic.maxCount)) 款") {
                library.addToCompare(targets)
                library.tab = .compare
            }
        }
        Divider()
        let allFavorite = targets.allSatisfy { library.mark(for: $0).isFavorite }
        Button(allFavorite ? LocalizedStringKey("取消常用") : LocalizedStringKey("标为常用")) { library.setFavorite(!allFavorite, for: targets) }
        Menu("能不能商用") {
            Button("标为可商用") { library.setCommercial(true, for: targets) }
            Button("标为不可商用") { library.setCommercial(false, for: targets) }
            Divider()
            Button("按字体里的授权说明（自动）") { library.setCommercial(nil, for: targets) }
        }
        Divider()
        Button("在访达中显示") {
            let urls = targets.flatMap(\.paths).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        Button("拷贝 PostScript 名称") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(family.faces.map(\.postScriptName).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Menu("加入字体集") {
            ForEach(library.manifest.sets) { set in
                Button(set.name) { library.add(targets, to: set.id) }
            }
            if !library.manifest.sets.isEmpty { Divider() }
            Button("新建字体集…") {
                guard ShelfTools.requirePro() else { return }
                newSetName = ""
                newSetTargets = targets
            }
        }
    }
}

extension FontCommercialStatus {
    var title: String {
        switch self {
        case .yes: return String(localized: "可商用")
        case .no: return String(localized: "不可商用")
        case .unknown: return String(localized: "授权不明")
        }
    }

    var tint: Color {
        switch self {
        case .yes: return .green
        case .no: return .red
        case .unknown: return .secondary
        }
    }
}

extension FontPreviewColors {
    var title: String {
        switch self {
        case .blackOnWhite: return String(localized: "黑字白底")
        case .whiteOnBlack: return String(localized: "白字黑底")
        case .accent: return String(localized: "品牌色")
        }
    }
}

extension FontGuideKind {
    var title: String {
        switch self {
        case .baseline: return String(localized: "基线")
        case .xHeight: return String(localized: "x 高")
        case .capHeight: return String(localized: "大写高")
        }
    }
}

/// 网格卡片的字色和底色。
enum FontPreviewPalette {
    @MainActor
    static func colors(_ option: FontPreviewColors) -> (text: NSColor, background: NSColor) {
        switch option {
        case .blackOnWhite:
            return (.black, .white)
        case .whiteOnBlack:
            return (.white, NSColor(white: 0.09, alpha: 1))
        case .accent:
            // 品牌色：跟着设置 › 外观 › 主题色（默认是系统强调色）。
            let accent = NSColor(AppearanceStore.shared.settings.accent.swatch)
            return (accent, accent.withAlphaComponent(0.09))
        }
    }
}

// MARK: - 网格上面的设置条

struct FontPreviewToolbar: View {
    @Binding var sample: String
    @Binding var size: Double
    @Binding var tracking: Double
    @Binding var colorsRaw: String
    @Binding var unify: Bool
    @Binding var guides: Bool
    @AppStorage(FontSamplePresets.storageKey) private var presetsRaw = ""
    @State private var showCustom = false
    @State private var customDraft = ""
    @State private var showSave = false
    @State private var saveName = ""

    private var custom: [FontSamplePreset] { FontSamplePresets.decode(presetsRaw) }

    var body: some View {
        // 窗口窄时放不下的控件换到下一行（滑块也会先变短）。
        AdaptiveRow(spacing: 14) {
            presetMenu
                .frame(minWidth: 120, idealWidth: 240, maxWidth: 240)
            HStack(spacing: 6) {
                Text("字号").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Slider(value: $size, in: 12...120)
                    .frame(minWidth: 60, idealWidth: 110, maxWidth: 110)
                Text(verbatim: "\(Int(size))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text("字距").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Slider(value: $tracking, in: FontTracking.range, step: 5)
                    .frame(minWidth: 60, idealWidth: 100, maxWidth: 100)
                Text(verbatim: FontTracking.label(tracking))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .help("单位是千分之一个字。按住 Option 在字体上双指缩放也能调")
            HStack(spacing: 6) {
                Text("颜色").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                ForEach(FontPreviewColors.allCases) { option in
                    colorButton(option)
                }
            }
            Toggle("统一视觉大小", isOn: $unify)
                .toggleStyle(.switch)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
                .help("大小不一的字体看起来一样大：西文按 x 高、中文按字身对齐")
            Toggle("辅助线", isOn: $guides)
                .toggleStyle(.switch)
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
                .help("显示基线、x 高、大写高")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .alert("自定义句子", isPresented: $showCustom) {
            TextField("输入要预览的句子", text: $customDraft)
            Button("使用") {
                let text = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { sample = text }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("存为预设", isPresented: $showSave) {
            TextField("预设名字（可以不填）", text: $saveName)
            Button("存") {
                presetsRaw = FontSamplePresets.encode(FontSamplePresets.adding(name: saveName, text: sample, to: custom))
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("把现在的样张句子存成预设，以后在「样张」菜单里一点就换。")
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("预设") {
                ForEach(FontSamplePresets.builtIn) { preset in
                    Button(preset.name) { sample = preset.text }
                }
            }
            if !custom.isEmpty {
                Section("我的预设") {
                    ForEach(custom) { preset in
                        Button(preset.name) { sample = preset.text }
                    }
                }
            }
            Divider()
            Button("自定义句子…") {
                customDraft = sample
                showCustom = true
            }
            Button("把当前句子存为预设…") {
                saveName = ""
                showSave = true
            }
            if !custom.isEmpty {
                Menu("删除预设") {
                    ForEach(custom) { preset in
                        Button(preset.name) {
                            presetsRaw = FontSamplePresets.encode(FontSamplePresets.removing(name: preset.name, from: custom))
                        }
                    }
                }
            }
        } label: {
            Text("样张：\(sample)")
                .lineLimit(1)
        }
    }

    private func colorButton(_ option: FontPreviewColors) -> some View {
        let colors = FontPreviewPalette.colors(option)
        let on = colorsRaw == option.rawValue
        return Button {
            colorsRaw = option.rawValue
        } label: {
            Text(verbatim: "A")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: colors.text))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: colors.background)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: on ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(option.title)
    }
}

// MARK: - 网格卡片

struct FontGridCard: View {
    let family: FontFamily
    let mark: FontMark
    let status: FontCommercialStatus
    let sample: String
    let size: Double
    let tracking: Double
    let palette: (text: NSColor, background: NSColor)
    let unify: Bool
    let guides: Bool
    let selected: Bool

    private var styleSummary: String {
        let styles = family.faces.map { $0.style.isEmpty ? $0.postScriptName : $0.style }.uniqued()
        return styles.prefix(3).joined(separator: " · ") + (styles.count > 3 ? " …" : "")
    }

    var body: some View {
        let face = family.representative
        let coversCJK = face?.coversCJK ?? false
        let text = FontSamplePresets.displayText(sample, coversCJK: coversCJK)
        let cjkText = coversCJK && text.unicodeScalars.contains(where: FontSamplePresets.isCJK)
        let font = face.flatMap { FontPreviewFonts.font(for: $0, size: CGFloat(size), unify: unify, cjkText: cjkText) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: family.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if mark.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("常用")
                }
                Spacer(minLength: 4)
                Text("\(family.styleCount) 款")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FontLineCanvas(font: font, text: text, color: palette.text, trackingEm: CGFloat(tracking), guides: guides,
                           placeholder: face?.location == .archived
                               ? String(localized: "已压缩存放，取回后可以预览") : String(localized: "无法预览"))
                .frame(height: max(56, CGFloat(size) * 1.8))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: palette.background)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 6) {
                Text(verbatim: styleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: status.title)
                    .font(.caption)
                    .foregroundStyle(status.tint)
                    .help(mark.commercial != nil ? String(localized: "你手动标的") : String(localized: "按字体文件里写的授权说明判断，仅供参考，以字体厂商的授权为准"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
        )
    }
}

/// 预览用的 CTFont（从文件读，停用的也能看）。
enum FontPreviewFonts {
    static func font(for face: FontFace, size: CGFloat) -> CTFont? {
        FontPreviewCache.font(for: face, size: size).map { $0 as CTFont }
    }

    /// 统一视觉大小时按字体自己的高度换算字号（西文看 x 高，中文看字身）。
    static func font(for face: FontFace, size: CGFloat, unify: Bool, cjkText: Bool) -> CTFont? {
        guard let font = font(for: face, size: size) else { return nil }
        guard unify else { return font }
        let metrics = FontMetricsSample(size: Double(size), ascent: Double(CTFontGetAscent(font)), descent: Double(CTFontGetDescent(font)),
                                        capHeight: Double(CTFontGetCapHeight(font)), xHeight: Double(CTFontGetXHeight(font)),
                                        coversCJK: cjkText)
        let scale = FontVisualSize.scale(metrics)
        guard abs(scale - 1) > 0.01 else { return font }
        return CTFontCreateCopyWithAttributes(font, size * CGFloat(scale), nil, nil)
    }

    /// SwiftUI 用的字体；读不出来时用系统字体。
    static func swiftUIFont(_ face: FontFace?, size: Double) -> Font {
        if let face, let font = font(for: face, size: CGFloat(size)) { return Font(font) }
        return .system(size: CGFloat(size))
    }
}

// MARK: - 用 Core Text 画一行字（字距、颜色、辅助线）

struct FontLineCanvas: NSViewRepresentable {
    let font: CTFont?
    let text: String
    var color: NSColor = .labelColor
    /// 字距，千分之一个字。
    var trackingEm: CGFloat = 0
    var guides = false
    var centered = false
    var placeholder = ""

    func makeNSView(context: Context) -> FontLineCanvasView { FontLineCanvasView() }

    func updateNSView(_ view: FontLineCanvasView, context: Context) {
        view.font = font
        view.text = text
        view.color = color
        view.trackingEm = trackingEm
        view.guides = guides
        view.centered = centered
        view.placeholder = placeholder
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FontLineCanvasView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: proposal.height ?? 48)
    }
}

final class FontLineCanvasView: NSView {
    var font: CTFont?
    var text = ""
    var color: NSColor = .labelColor
    var trackingEm: CGFloat = 0
    var guides = false
    var centered = false
    var placeholder = ""

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 12
        guard let font else {
            let label = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: inset, y: (bounds.height - size.height) / 2))
            return
        }
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baseline = CGFloat(FontGuides.baselineY(height: Double(bounds.height), ascent: Double(ascent), descent: Double(descent)))
        if guides { drawGuides(context, font: font, baseline: baseline) }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): FontTracking.points(Double(trackingEm), size: Double(CTFontGetSize(font))),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let available = Double(bounds.width - inset * 2)
        var drawn = line
        if CTLineGetTypographicBounds(line, nil, nil, nil) > available, available > 0 {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            drawn = CTLineCreateTruncatedLine(line, available, .end, token) ?? line
        }
        let width = CGFloat(CTLineGetTypographicBounds(drawn, nil, nil, nil))
        let x = centered ? max(inset, (bounds.width - width) / 2) : inset
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(drawn, context)
        context.restoreGState()
    }

    private func drawGuides(_ context: CGContext, font: CTFont, baseline: CGFloat) {
        let metrics = FontMetricsSample(size: Double(CTFontGetSize(font)), ascent: Double(CTFontGetAscent(font)),
                                        descent: Double(CTFontGetDescent(font)), capHeight: Double(CTFontGetCapHeight(font)),
                                        xHeight: Double(CTFontGetXHeight(font)), coversCJK: false)
        for guide in FontGuides.lines(metrics) {
            let y = (baseline + CGFloat(guide.offset)).rounded() + 0.5
            let tint: NSColor = guide.kind == .baseline ? .systemRed : .systemBlue
            context.saveGState()
            context.setStrokeColor(tint.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
            context.strokePath()
            context.restoreGState()
            let label = NSAttributedString(string: guide.kind.title, attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: tint.withAlphaComponent(0.75),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - size.width - 4, y: y + 1))
        }
    }
}

// MARK: - 详情面板

enum FontDetailTab: String, CaseIterable, Identifiable {
    case body, characters, features, variations, info
    var id: String { rawValue }

    var title: String {
        switch self {
        case .body: return String(localized: "正文")
        case .characters: return String(localized: "字符")
        case .features: return String(localized: "特性")
        case .variations: return String(localized: "可变")
        case .info: return String(localized: "信息")
        }
    }
}

struct FontDetailPanel: View {
    @ObservedObject private var extras = FontExtraInfoStore.shared
    let family: FontFamily
    let onClose: () -> Void
    @AppStorage("fonts.detailTab") private var tabRaw = FontDetailTab.body.rawValue
    @State private var faceID: String? = nil

    private var tab: FontDetailTab { FontDetailTab(rawValue: tabRaw) ?? .body }
    private var face: FontFace? { family.faces.first { $0.id == faceID } ?? family.representative }

    private var subtitle: String {
        let info = extras.info(for: family.representative)
        let version = family.representative.map { FontVersion.number($0.version) ?? $0.version } ?? ""
        return [info?.manufacturer ?? "", version].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: family.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭")
            }
            // 面板窄时换成下拉菜单（分段控件不会自己变窄）。
            AdaptiveSegmentedPicker(title: "", selection: $tabRaw) {
                ForEach(FontDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab.rawValue)
                }
            }
            if family.faces.count > 1 {
                Picker("样式", selection: Binding(get: { face?.id ?? "" }, set: { faceID = $0 })) {
                    ForEach(family.faces) { face in
                        Text(verbatim: face.style.isEmpty ? face.postScriptName : face.style).tag(face.id)
                    }
                }
                .frame(maxWidth: 280)
            }
            Group {
                if let face {
                    switch tab {
                    case .body:
                        FontBodyTab(face: face, titleFace: faceID == nil ? (FontBodyLogic.titleFace(in: family.faces) ?? face) : face)
                    case .characters:
                        FontCharactersTab(family: family, face: face).proGated(.fontInspector)
                    case .features:
                        FontFeaturesTab(face: face).proGated(.fontInspector)
                    case .variations:
                        FontVariationsTab(face: face).proGated(.fontInspector)
                    case .info:
                        FontInfoTab(family: family, face: face)
                    }
                } else {
                    Text("无法预览").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .task(id: family.id) { extras.load(family.faces) }
    }
}

// MARK: - 正文排版

extension FontBodyStyle {
    var title: String {
        switch self {
        case .book: return String(localized: "书籍")
        case .magazine: return String(localized: "杂志")
        case .web: return String(localized: "网页")
        case .custom: return String(localized: "自定义…")
        }
    }
}

struct FontBodyTab: View {
    let face: FontFace
    let titleFace: FontFace
    @AppStorage("fonts.bodyStyle") private var styleRaw = FontBodyStyle.magazine.rawValue
    @AppStorage(FontBodyLogic.storageKey) private var customRaw = ""
    @State private var editing = false

    private var style: FontBodyStyle { FontBodyStyle(rawValue: styleRaw) ?? .magazine }
    private var customSpec: FontBodySpecimen { FontBodyLogic.decode(customRaw) ?? FontBodyLogic.preset(.custom, cjk: face.coversCJK) }
    private var spec: FontBodySpecimen { style == .custom ? customSpec : FontBodyLogic.preset(style, cjk: face.coversCJK) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $styleRaw) {
                    ForEach(FontBodyStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Spacer()
                if style == .custom {
                    Button("编辑…") { editing = true }
                }
            }
            ScrollView {
                FontBodyPage(spec: spec, face: face, titleFace: titleFace)
                    .padding(22)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .onChange(of: styleRaw) { _, value in
            // 第一次选「自定义…」：直接打开编辑。
            if value == FontBodyStyle.custom.rawValue, FontBodyLogic.decode(customRaw) == nil { editing = true }
        }
        .sheet(isPresented: $editing) {
            FontBodyEditor(spec: customSpec, cjk: face.coversCJK) { customRaw = FontBodyLogic.encode($0) }
        }
    }
}

/// 一页正文：栏目、标题、副标题、分栏正文，全部用这款字体。
struct FontBodyPage: View {
    let spec: FontBodySpecimen
    let face: FontFace
    let titleFace: FontFace

    var body: some View {
        let columns = FontBodyLogic.columns(FontBodyLogic.paragraphs(spec.body), count: spec.columns)
        let spacing = CGFloat(FontBodyLogic.lineSpacing(size: spec.bodySize, leading: spec.leading))
        VStack(alignment: .leading, spacing: 10) {
            if !spec.kicker.isEmpty {
                Text(verbatim: spec.kicker)
                    .font(FontPreviewFonts.swiftUIFont(face, size: spec.bodySize * 0.9))
                    .foregroundStyle(.orange)
            }
            Text(verbatim: spec.title)
                .font(FontPreviewFonts.swiftUIFont(titleFace, size: spec.titleSize))
                .fixedSize(horizontal: false, vertical: true)
            if !spec.subtitle.isEmpty {
                Text(verbatim: spec.subtitle)
                    .font(FontPreviewFonts.swiftUIFont(face, size: spec.bodySize * 1.2))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: max(14, CGFloat(spec.bodySize) * 1.5)) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: CGFloat(spec.bodySize) * 0.9) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, paragraph in
                            Text(verbatim: paragraph)
                                .font(FontPreviewFonts.swiftUIFont(face, size: spec.bodySize))
                                .lineSpacing(spacing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(Color(nsColor: .textColor))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// 自定义正文样张：标题、正文、字号、行距、分栏，存下来下次还在。
struct FontBodyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var spec: FontBodySpecimen
    let cjk: Bool
    let onSave: (FontBodySpecimen) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义正文样张").font(.title3.weight(.semibold))
            TextField("栏目（可以不填）", text: $spec.kicker)
            TextField("标题", text: $spec.title)
            TextField("副标题（可以不填）", text: $spec.subtitle)
            Text("正文（空一行分段）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $spec.body)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("标题字号")
                    Slider(value: $spec.titleSize, in: FontBodyLogic.titleRange, step: 1)
                    Text(verbatim: "\(Int(spec.titleSize)) pt").monospacedDigit()
                }
                GridRow {
                    Text("正文字号")
                    Slider(value: $spec.bodySize, in: FontBodyLogic.bodyRange, step: 0.5)
                    Text(verbatim: String(format: "%.1f pt", spec.bodySize)).monospacedDigit()
                }
                GridRow {
                    Text("行距")
                    Slider(value: $spec.leading, in: FontBodyLogic.leadingRange, step: 0.05)
                    Text(verbatim: String(format: "%.2f", spec.leading)).monospacedDigit()
                }
                GridRow {
                    Text("分栏")
                    Picker("", selection: $spec.columns) {
                        Text("单栏").tag(1)
                        Text("两栏").tag(2)
                        Text("三栏").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            HStack {
                Button("恢复默认") { spec = FontBodyLogic.preset(.custom, cjk: cjk) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(spec)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 信息

struct FontInfoTab: View {
    @ObservedObject private var library = FontLibrary.shared
    @ObservedObject private var extras = FontExtraInfoStore.shared
    let family: FontFamily
    let face: FontFace

    var body: some View {
        let info = extras.info(for: face)
        let mark = library.mark(for: family)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(family.locations, id: \.self) { FontLocationBadge(location: $0) }
                    FontCommercialBadge(status: library.commercialStatus(family), manual: mark.commercial != nil)
                    if mark.isFavorite {
                        Label("常用", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if family.coversCJK {
                        Text("中文字体")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    infoRow("厂商", info?.manufacturer)
                    infoRow("设计师", info?.designer)
                    infoRow("版本", face.version)
                    infoRow("字数", (info?.glyphCount ?? 0) > 0 ? info?.glyphCount.formatted() : nil)
                    infoRow("格式", family.formats.map(\.label).joined(separator: " / ")
                        + (family.isVariable ? " · " + String(localized: "可变字体") : ""))
                    infoRow("分类", family.styleClass == .other ? nil : family.styleClass.title)
                    infoRow("总大小", family.totalBytes.byteText)
                    infoRow("版权", info?.copyright)
                    infoRow("商标", info?.trademark)
                    infoRow("说明", info?.descriptionText)
                }
                .font(.callout)
                Divider()
                Text("\(family.styleCount) 个样式").font(.headline)
                ForEach(family.faces) { face in
                    FontFaceInfoRow(face: face)
                }
                Divider()
                FontLicenseLine(text: family.licenseText, url: family.licenseURL)
                HStack {
                    Button("在访达中显示") {
                        let urls = family.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                    }
                    Button("拷贝 PostScript 名称") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(family.faces.map(\.postScriptName).joined(separator: "\n"), forType: .string)
                    }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func infoRow(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GridRow {
                Text(title)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(verbatim: value)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 信息页里的一个字形：样式、格式、位置、大小，PostScript 名字和路径。
struct FontFaceInfoRow: View {
    let face: FontFace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: face.style.isEmpty ? face.postScriptName : face.style)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: face.format.label + (face.isVariable ? " · " + String(localized: "可变") : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FontLocationBadge(location: face.location)
                if face.isDamaged {
                    Text("已损坏").font(.caption).foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Text(verbatim: face.fileSize.byteText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: face.postScriptName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(verbatim: face.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(face.path)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 字体网格框选

/// 卡片在网格坐标里的位置（引用类型：滚动时更新不让整个网格重画）。
final class FontCardFrames {
    var frames: [String: CGRect] = [:]
}

struct FontCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 框选：只有 FontMarqueeOverlay 观察它，矩形每帧变化时网格本身不重画。
@MainActor
final class FontMarqueeModel: ObservableObject {
    @Published private(set) var rect: CGRect?
    private(set) var active = false
    /// ⌃点按：留给右键菜单，这次拖动什么都不做。
    private var ignored = false
    private var cancelled = false
    private var start: CGPoint = .zero
    private var location: CGPoint = .zero
    private var base: Set<String> = []
    private var toggle = false
    private var ids: Set<String> = []
    private var lastApply: TimeInterval = 0

    func begin(at point: CGPoint, flags: NSEvent.ModifierFlags, base: Set<String>, ids: Set<String>) {
        active = true
        cancelled = false
        ignored = flags.contains(.control)
        start = point
        location = point
        toggle = flags.contains(.command)
        self.base = base
        self.ids = ids
        lastApply = 0
    }

    /// 拖动中：返回新的选中（最多每 30 毫秒一次；矩形太小时返回 nil）。
    func update(to point: CGPoint, frames: [String: CGRect]) -> Set<String>? {
        guard active, !ignored, !cancelled else { return nil }
        location = point
        return apply(frames: frames, force: false)
    }

    /// 结束拖动。wasClick：只是点了一下空白处（调用方清空选中）。
    func end(at point: CGPoint, frames: [String: CGRect]) -> (selection: Set<String>?, wasClick: Bool) {
        defer { reset() }
        guard active, !ignored, !cancelled else { return (nil, false) }
        location = point
        let moved = hypot(location.x - start.x, location.y - start.y)
        if moved < 3 { return (nil, !toggle) }
        return (apply(frames: frames, force: true), false)
    }

    /// Esc：正在框选时返回开始前的选中。
    func cancel() -> Set<String>? {
        guard active, !ignored, !cancelled else { return nil }
        cancelled = true
        rect = nil
        return base
    }

    private func reset() {
        active = false
        ignored = false
        cancelled = false
        if rect != nil { rect = nil }
    }

    private func apply(frames: [String: CGRect], force: Bool) -> Set<String>? {
        let r = FontSelectionLogic.rect(from: start, to: location)
        guard r.width >= 3 || r.height >= 3 else {
            if rect != nil { rect = nil }
            return nil
        }
        rect = r
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastApply >= 0.03 else { return nil }
        lastApply = now
        let hit = FontSelectionLogic.hits(frames, rect: r).intersection(ids)
        return FontSelectionLogic.marqueeSelection(base: base, hit: hit, toggle: toggle)
    }
}

/// 框选矩形（半透明的强调色）。
struct FontMarqueeOverlay: View {
    @ObservedObject var model: FontMarqueeModel

    var body: some View {
        if let rect = model.rect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }
}
