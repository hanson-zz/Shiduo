import AppKit
import SwiftUI

// MARK: - 字体页

/// 字体页：字体库、样张、问题字体、已停用（免费）；字体集（Pro）。
struct FontsView: View {
    @ObservedObject private var library = FontLibrary.shared
    @State private var query = ""
    @AppStorage("fonts.filter") private var filterRaw = FontFilter.all.rawValue
    @AppStorage("fonts.sort") private var sortRaw = FontSortKey.name.rawValue

    private var filter: FontFilter { FontFilter(rawValue: filterRaw) ?? .all }
    private var sort: FontSortKey { FontSortKey(rawValue: sortRaw) ?? .name }

    private var shownFamilies: [FontFamily] {
        let marks = library.manifest.marks ?? [:]
        let list = library.families.filter {
            FontLibraryLogic.passes($0, filter: filter, marks: marks) && FontLibraryLogic.matches($0, query: query)
        }
        return FontLibraryLogic.sorted(list, by: sort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("字体")
        .task {
            library.scanIfNeeded()
            // 字体库扫完后在后台顺便看一眼下载里有没有新字体（标签上显示个数）。
            while !library.hasScanned, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
            library.scanDownloadsIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("字体")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let busy = library.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
                Button {
                    library.scan()
                } label: {
                    HStack(spacing: 6) {
                        if library.isScanning { ProgressView().controlSize(.small) }
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .glassCapsule()
                }
                .buttonStyle(.plain)
                .disabled(library.isScanning)
            }
            HStack(spacing: 10) {
                Picker("", selection: $library.tab) {
                    ForEach(FontsTab.allCases) { tab in
                        Text(tabLabel(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 700)
                Spacer()
                if library.tab == .library || library.tab == .specimen {
                    TextField("搜索字体（中文名、英文名、拼音首字母）", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Picker("筛选", selection: $filterRaw) {
                        Text("全部字体").tag(FontFilter.all.rawValue)
                        Text("中文字体").tag(FontFilter.cjk.rawValue)
                        Divider()
                        Text("用户字体").tag(FontFilter.user.rawValue)
                        Text("本机字体").tag(FontFilter.local.rawValue)
                        Text("系统字体").tag(FontFilter.system.rawValue)
                        Text("已停用").tag(FontFilter.stored.rawValue)
                        Divider()
                        Text("衬线 / 宋体").tag(FontFilter.serif.rawValue)
                        Text("无衬线 / 黑体").tag(FontFilter.sans.rawValue)
                        Text("等宽").tag(FontFilter.mono.rawValue)
                        Text("手写 / 楷书").tag(FontFilter.script.rawValue)
                        Text("装饰").tag(FontFilter.decorative.rawValue)
                        Divider()
                        Text("★ 常用").tag(FontFilter.favorites.rawValue)
                        Text("可商用").tag(FontFilter.commercial.rawValue)
                        Text("不可商用").tag(FontFilter.notCommercial.rawValue)
                        Text("授权不明").tag(FontFilter.licenseUnknown.rawValue)
                    }
                    .frame(width: 140)
                    if library.tab == .library {
                        Picker("排序", selection: $sortRaw) {
                            Text("名称").tag(FontSortKey.name.rawValue)
                            Text("大小").tag(FontSortKey.size.rawValue)
                            Text("总占用").tag(FontSortKey.total.rawValue)
                            Text("添加日期").tag(FontSortKey.added.rawValue)
                        }
                        .frame(width: 130)
                    }
                }
            }
        }
    }

    private func tabLabel(_ tab: FontsTab) -> String {
        switch tab {
        case .problems where library.actionableIssueCount > 0:
            return tab.title + " \(library.actionableIssueCount)"
        case .stored where !library.manifest.entries.isEmpty:
            return tab.title + " \(library.manifest.entries.count)"
        case .compare where !library.compareIDs.isEmpty:
            return tab.title + " \(library.compareIDs.count)"
        case .downloads where library.newDownloadCount > 0:
            return tab.title + " \(library.newDownloadCount)"
        case .sets:
            return tab.title + " · PRO"
        default:
            return tab.title
        }
    }

    private var summary: String {
        guard library.hasScanned else {
            return String(localized: "正在读取字体…")
        }
        let userBytes = library.faces.filter { $0.location == .user }.uniqueFileBytes
        let cjk = library.families.filter(\.coversCJK).count
        return String(localized: "\(library.families.count) 个字体家族（中文 \(cjk) 个）· 用户字体占 \(userBytes.byteText)")
    }

    @ViewBuilder
    private var content: some View {
        if !library.hasScanned {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取字体…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch library.tab {
            case .library: FontLibraryTab(families: shownFamilies)
            case .specimen: FontSpecimenTab(families: shownFamilies)
            case .compare: FontCompareTab()
            case .downloads: FontDownloadsTab()
            case .problems: FontProblemsTab()
            case .stored: FontStoredTab()
            case .sets: FontSetsTab().proGated(.fontSets)
            }
        }
    }
}

extension Array where Element == FontFace {
    /// 不同文件的总大小（TTC 只算一次）。
    var uniqueFileBytes: Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for face in self where seen.insert(face.path).inserted { total += face.fileSize }
        return total
    }
}

extension FontLocation {
    var title: String {
        switch self {
        case .user: return String(localized: "用户")
        case .local: return String(localized: "本机")
        case .system: return String(localized: "系统")
        case .disabled: return String(localized: "已停用")
        case .external: return String(localized: "移动硬盘")
        case .archived: return String(localized: "已压缩")
        }
    }

    var tint: Color {
        switch self {
        case .user: return .blue
        case .local: return .teal
        case .system: return .gray
        case .disabled: return .orange
        case .external: return .purple
        case .archived: return .brown
        }
    }
}

/// 位置小标签：用户 / 本机 / 系统 / 已停用……
struct FontLocationBadge: View {
    let location: FontLocation

    var body: some View {
        Text(location.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(location.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(location.tint.opacity(0.14)))
            .fixedSize()
    }
}

// MARK: - 用字体本身显示文字

/// 用这个字体显示一段文字（从文件直接读，停用的字体没注册也能预览）。
struct FontSampleText: NSViewRepresentable {
    let face: FontFace
    let text: String
    let size: CGFloat
    var lines: Int = 1
    /// 文字颜色（叠放对比时用）；nil = 系统文字颜色。
    var color: NSColor? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.maximumNumberOfLines = lines
        field.usesSingleLineMode = lines == 1
        field.cell?.wraps = lines > 1
        field.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        if let font = FontPreviewCache.font(for: face, size: size) {
            field.font = font
            field.textColor = color ?? .labelColor
            field.stringValue = text
        } else {
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.stringValue = face.location == .archived
                ? String(localized: "已压缩存放，取回后可以预览")
                : String(localized: "无法预览")
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let lineHeight = max(16, size * 1.35)
        return CGSize(width: width, height: lineHeight * CGFloat(lines))
    }
}

// MARK: - 字体库

private struct FontLibraryTab: View {
    @ObservedObject private var library = FontLibrary.shared
    let families: [FontFamily]
    @State private var selection: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var newSetFor: FontFamily?
    @State private var newSetName = ""

    private var selectedFamilies: [FontFamily] { families.filter { selection.contains($0.id) } }
    private var selectedUserPaths: [String] {
        selectedFamilies.flatMap { family in family.faces.filter { $0.location == .user }.map(\.path) }.uniqued()
    }
    private var selectedStoredIDs: [UUID] {
        selectedFamilies.flatMap { family in family.faces.compactMap(\.manifestID) }.uniqued()
    }

    var body: some View {
        VStack(spacing: 0) {
            if families.isEmpty {
                Text("没有符合条件的字体")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(families) { family in
                        FontFamilyRow(family: family, mark: library.mark(for: family), status: library.commercialStatus(family),
                                      expanded: expanded.contains(family.id)) {
                            if expanded.contains(family.id) { expanded.remove(family.id) } else { expanded.insert(family.id) }
                        }
                        .tag(family.id)
                        .stableContextMenu { menu(for: family) }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack(spacing: 10) {
                Label("系统字体只显示、不会动；/Library/Fonts 里的要管理员权限，拾掇也不改。停用是移进拾掇的字体仓库，不是删除。",
                      systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
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
                    let paths = selectedUserPaths
                    Task { await library.disable(paths: paths) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedUserPaths.isEmpty || library.busy != nil)
                .help("只停用「用户字体」（~/Library/Fonts 里的）")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .alert("新建字体集", isPresented: Binding(get: { newSetFor != nil }, set: { if !$0 { newSetFor = nil } })) {
            TextField("名字，比如「客户A 品牌」", text: $newSetName)
            Button("新建") {
                if let family = newSetFor, let set = library.createSet(name: newSetName) {
                    library.add(family, to: set.id)
                }
                newSetFor = nil
                newSetName = ""
            }
            Button("取消", role: .cancel) {
                newSetFor = nil
                newSetName = ""
            }
        }
    }

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
                Button(set.name) { library.add(family, to: set.id) }
            }
            if !library.manifest.sets.isEmpty { Divider() }
            Button("新建字体集…") {
                guard ShelfTools.requirePro() else { return }
                newSetName = ""
                newSetFor = family
            }
        }
    }
}

private struct FontFamilyRow: View {
    let family: FontFamily
    let mark: FontMark
    let status: FontCommercialStatus
    let expanded: Bool
    let toggle: () -> Void

    private var detail: String {
        var parts = [String(localized: "\(family.styleCount) 个样式")]
        if family.styleClass != .other { parts.append(family.styleClass.title) }
        parts.append(family.formats.map(\.label).joined(separator: " / "))
        if family.isVariable { parts.append(String(localized: "可变字体")) }
        if family.faces.contains(where: \.isDamaged) { parts.append(String(localized: "已损坏")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(family.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if family.coversCJK {
                            Text("中")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                                .help("包含常用汉字")
                        }
                        if mark.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .help("常用")
                        }
                        FontCommercialBadge(status: status, manual: mark.commercial != nil)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 180, alignment: .leading)
                if let face = family.representative {
                    FontSampleText(face: face, text: face.coversCJK ? "永和九年 Aa" : "Aa Bb 0123", size: 18)
                        .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(family.locations, id: \.self) { FontLocationBadge(location: $0) }
                }
                Text(family.totalBytes.byteText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(family.faces) { face in
                        FontFaceRow(face: face)
                    }
                    FontLicenseLine(text: family.licenseText, url: family.licenseURL)
                }
                .padding(.leading, 24)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FontFaceRow: View {
    let face: FontFace

    var body: some View {
        HStack(spacing: 8) {
            Text(face.style.isEmpty ? face.postScriptName : face.style)
                .font(.callout.weight(.medium))
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
            Text(face.postScriptName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)
                .textSelection(.enabled)
            Text(face.format.label + (face.isVariable ? " · " + String(localized: "可变") : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(face.version.isEmpty ? "" : face.version)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            FontLocationBadge(location: face.location)
            Text(face.fileSize.byteText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(face.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(face.path)
        }
    }
}

// MARK: - 样张

private struct FontSpecimenTab: View {
    let families: [FontFamily]
    @AppStorage("fonts.sampleText") private var sample = FontCoverage.defaultSample
    @AppStorage("fonts.sampleSize") private var size = 28.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("样张文字", text: $sample)
                    .textFieldStyle(.roundedBorder)
                Button("恢复默认") { sample = FontCoverage.defaultSample }
                    .disabled(sample == FontCoverage.defaultSample)
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $size, in: 12...96)
                    .frame(width: 160)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                Text("\(Int(size)) pt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            if families.isEmpty {
                Text("没有符合条件的字体")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: max(260, size * 9)), spacing: 14)], spacing: 14) {
                        ForEach(families) { family in
                            FontSpecimenCard(family: family, sample: sample.isEmpty ? FontCoverage.defaultSample : sample, size: CGFloat(size))
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

private struct FontSpecimenCard: View {
    let family: FontFamily
    let sample: String
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(family.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                ForEach(family.locations, id: \.self) { FontLocationBadge(location: $0) }
            }
            if let face = family.representative {
                FontSampleText(face: face, text: sample, size: size, lines: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("\(family.styleCount) 个样式 · \(family.totalBytes.byteText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }
}

// MARK: - 问题字体

private struct FontProblemsTab: View {
    @ObservedObject private var library = FontLibrary.shared
    /// 勾选的（默认一个都不勾）。
    @State private var checked: Set<String> = []
    @State private var confirmTrash = false

    /// 能勾的（含撞车组，手动勾）。
    private var actionablePaths: Set<String> {
        Set(library.issues.flatMap(\.actionableExtras).map(\.path))
    }
    /// 「按建议勾选」勾的（不含撞车组）。
    private var suggestedPaths: Set<String> {
        Set(library.issues.flatMap(\.suggestedExtras).map(\.path))
    }
    private var checkedPaths: [String] { checked.filter(actionablePaths.contains).sorted() }
    private var checkedBytes: Int64 {
        library.issues.flatMap(\.actionableExtras).filter { checked.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            if library.issues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("没有重复、旧版本或损坏的字体")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(.duplicate, title: String(localized: "重复的字体"),
                                subtitle: String(localized: "同一个字体装了好几份，版本也一样：留一份就够"))
                        section(.versions, title: String(localized: "多个版本"),
                                subtitle: String(localized: "同一个字体装了不同版本，容易用错：建议留版本最高的"))
                        section(.conflict, title: String(localized: "名字撞车"),
                                subtitle: String(localized: "名字一样但内容不一样（比如粗体被写成常规体的名字）：系统只认其中一个。先看样式和字重再决定，不会帮你勾"))
                        section(.damaged, title: String(localized: "损坏的字体"),
                                subtitle: String(localized: "系统读不出来（可能下载不完整或已损坏），装着也用不了"))
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button("按建议勾选") { checked = suggestedPaths }
                    .disabled(suggestedPaths.isEmpty)
                Button("全不勾") { checked = [] }
                    .disabled(checked.isEmpty)
                Spacer()
                Button("移到废纸篓…") { confirmTrash = true }
                    .disabled(checkedPaths.isEmpty || library.busy != nil)
                    .help("也可以直接移到废纸篓（30 天内可以在「清理记录」里放回）")
                Button("停用勾选的（\(checkedPaths.count) 个 · \(checkedBytes.byteText)）") {
                    let paths = checkedPaths
                    checked = []
                    Task { await library.disable(paths: paths) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkedPaths.isEmpty || library.busy != nil)
                .help("移进拾掇的字体仓库，随时可以在「已停用」里启用")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .confirmationDialog("把 \(checkedPaths.count) 个字体文件移到废纸篓？", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                let paths = checkedPaths
                checked = []
                library.trash(paths: paths)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("推荐用「停用」：不删文件，以后还能一键启用。移到废纸篓后 30 天内可以在「清理记录」里放回。")
        }
    }

    @ViewBuilder
    private func section(_ kind: FontIssueGroup.Kind, title: String, subtitle: String) -> some View {
        let groups = library.issues.filter { $0.kind == kind }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    FontIssueCard(group: group, checked: $checked)
                }
            }
        }
    }
}

private struct FontIssueCard: View {
    let group: FontIssueGroup
    @Binding var checked: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.headline)
            if let keep = group.keep {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("建议保留").font(.callout.weight(.medium))
                    fileLine(keep)
                }
            }
            ForEach(group.extras) { file in
                HStack(spacing: 8) {
                    if file.isActionable {
                        Toggle("", isOn: Binding(
                            get: { checked.contains(file.path) },
                            set: { on in if on { checked.insert(file.path) } else { checked.remove(file.path) } }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    } else {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help(FontLibrary.adminNote(1))
                    }
                    Text(reason(for: file)).font(.callout.weight(.medium))
                    fileLine(file)
                }
                .opacity(file.isActionable ? 1 : 0.6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private func reason(for file: FontFileInfo) -> String {
        switch group.kind {
        case .duplicate: return String(localized: "多余的一份")
        case .versions:
            if let keep = group.keep, FontVersion.same(file.version, keep.version) { return String(localized: "多余的一份") }
            return String(localized: "旧版本")
        case .damaged: return String(localized: "读不出来")
        case .conflict: return String(localized: "同名不同内容")
        }
    }

    /// 「Bold · 粗体 · 28,463 字」
    private func lookText(_ file: FontFileInfo) -> String {
        var parts: [String] = []
        let styles = file.styles.filter { !$0.isEmpty }.uniqued()
        if !styles.isEmpty { parts.append(styles.prefix(3).joined(separator: "/") + (styles.count > 3 ? "…" : "")) }
        parts.append(file.weightTitle)
        if file.glyphCount > 0 { parts.append(String(localized: "\(file.glyphCount.formatted()) 字")) }
        return parts.joined(separator: " · ")
    }

    private func fileLine(_ file: FontFileInfo) -> some View {
        HStack(spacing: 6) {
            FontLocationBadge(location: file.location)
            if !file.version.isEmpty {
                Text(file.version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            if group.kind != .damaged {
                Text(lookText(file))
                    .font(.caption)
                    .foregroundStyle(group.kind == .conflict ? .primary : .secondary)
                    .lineLimit(1)
                    .help("样式名 · 字重 · 字数")
            }
            Text(file.size.byteText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(file.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("在访达中显示")
        }
    }
}

// MARK: - 已停用

private struct FontStoredTab: View {
    @ObservedObject private var library = FontLibrary.shared
    @EnvironmentObject private var license: LicenseManager
    @State private var selection: Set<UUID> = []

    private var entries: [FontStoreEntry] { library.manifest.entries }
    private var selected: [FontStoreEntry] { entries.filter { selection.contains($0.id) } }
    private var selectedDisabled: [UUID] { selected.filter { $0.storage == .disabled }.map(\.id) }
    private var selectedAway: [UUID] { selected.filter { $0.storage != .disabled }.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("还没有停用的字体。在「字体库」里选中用户字体，点「停用」：字体移进拾掇的字体仓库，不是删除。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    group(.disabled, title: String(localized: "停用中（在拾掇字体仓库里）"))
                    group(.archived, title: String(localized: "压缩存放"))
                    group(.external, title: String(localized: "在移动硬盘 / 其他文件夹"))
                }
                .listStyle(.inset)
            }
            Divider()
            HStack(spacing: 10) {
                Button("启用") {
                    let ids = Array(selection)
                    Task { await library.enable(entryIDs: ids) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || library.busy != nil)
                .help("放回 ~/Library/Fonts，马上就能用")
                if !selectedAway.isEmpty {
                    Button("取回到字体仓库") {
                        let ids = selectedAway
                        Task { await library.retrieve(entryIDs: ids) }
                    }
                    .disabled(library.busy != nil)
                }
                Spacer()
                Button {
                    let ids = selectedDisabled
                    Task { await library.archive(entryIDs: ids) }
                } label: {
                    HStack(spacing: 4) {
                        Text("压缩存放")
                        if !license.isPro { ProBadge() }
                    }
                }
                .disabled(selectedDisabled.isEmpty || library.busy != nil)
                .help("打成 zip（中文字体通常能省一半），放在：\(library.archiveFolder)")
                Button {
                    chooseExternal()
                } label: {
                    HStack(spacing: 4) {
                        Text("搬到移动硬盘…")
                        if !license.isPro { ProBadge() }
                    }
                }
                .disabled(selectedDisabled.isEmpty || library.busy != nil)
                Menu {
                    Button("选择压缩存放的位置…") { chooseArchiveFolder() }
                    Button("恢复默认位置") { library.setArchiveFolder(nil) }
                        .disabled(library.manifest.archiveFolder == nil)
                    Divider()
                    Button("在访达中显示字体仓库") {
                        let url = URL(fileURLWithPath: FontPathRules.storeRoot(home: FontLibrary.home), isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func group(_ storage: FontStoreEntry.Storage, title: String) -> some View {
        let list = entries.filter { $0.storage == storage }
        let bytes = list.reduce(Int64(0)) { $0 + $1.size }
        if !list.isEmpty {
            Section {
                ForEach(list) { entry in
                    FontStoredRow(entry: entry)
                        .tag(entry.id)
                }
            } header: {
                Text("\(title) · \(list.count) 个 · \(bytes.byteText)")
            }
        }
    }

    private func chooseExternal() {
        guard ShelfTools.requirePro() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "搬到这里")
        panel.message = String(localized: "选一个移动硬盘或文件夹：字体会放进里面的「拾掇字体」文件夹")
        if FileManager.default.fileExists(atPath: "/Volumes") { panel.directoryURL = URL(fileURLWithPath: "/Volumes") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = selectedDisabled
        Task { await library.moveToExternal(entryIDs: ids, folder: url) }
    }

    private func chooseArchiveFolder() {
        guard ShelfTools.requirePro() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setArchiveFolder(url)
    }
}

private struct FontStoredRow: View {
    let entry: FontStoreEntry

    private var reachable: Bool { FileManager.default.fileExists(atPath: entry.storedPath) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayFamily.isEmpty ? entry.fileName : entry.displayFamily)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.storage == .external && !reachable {
                Label("移动硬盘没接上", systemImage: "externaldrive.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if entry.storage == .archived, let zipped = entry.archivedSize {
                Text("\(entry.size.byteText) → \(zipped.byteText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.size.byteText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.originalPath)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)
                .help(String(localized: "原来的位置：\(entry.originalPath)"))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 字体集（Pro）

private struct FontSetsTab: View {
    @ObservedObject private var library = FontLibrary.shared
    @State private var selectedID: UUID?
    @State private var showNew = false
    @State private var newName = ""
    @AppStorage(FontSetBinding.modeKey) private var modeRaw = FontSetBinding.Mode.ask.rawValue

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(library.manifest.sets) { set in
                        HStack {
                            Label(set.name, systemImage: "f.cursive")
                            Spacer()
                            if library.isActive(set) {
                                Circle().fill(Color.green).frame(width: 7, height: 7).help("已启用")
                            }
                        }
                        .tag(set.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button {
                        newName = ""
                        showNew = true
                    } label: {
                        Label("新建字体集", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 220)
            Divider()
            if let id = selectedID, let set = library.manifest.sets.first(where: { $0.id == id }) {
                FontSetDetail(set: set, onDelete: { selectedID = nil })
                    .id(set.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "f.cursive")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("按客户或品牌建一个字体集，平时字体停用着，要用时一键临时启用；绑定项目文件夹后，在拾掇里打开项目就能自动启用。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Picker("打开绑定的项目文件夹时", selection: $modeRaw) {
                        Text("询问我").tag(FontSetBinding.Mode.ask.rawValue)
                        Text("自动启用").tag(FontSetBinding.Mode.auto.rawValue)
                        Text("不处理").tag(FontSetBinding.Mode.off.rawValue)
                    }
                    .frame(maxWidth: 320)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("新建字体集", isPresented: $showNew) {
            TextField("名字，比如「客户A 品牌」", text: $newName)
            Button("新建") {
                if let set = library.createSet(name: newName) { selectedID = set.id }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if selectedID == nil { selectedID = library.manifest.sets.first?.id }
        }
    }
}

private struct FontSetDetail: View {
    @ObservedObject private var library = FontLibrary.shared
    let set: FontSet
    let onDelete: () -> Void
    @State private var name = ""
    @State private var showPicker = false
    @State private var confirmDelete = false
    @AppStorage(FontSetBinding.modeKey) private var modeRaw = FontSetBinding.Mode.ask.rawValue

    private var memberFamilies: [FontFamily] { FontLibraryLogic.families(library.members(of: set)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("字体集名字", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .frame(maxWidth: 320)
                        .onSubmit(rename)
                    Spacer()
                    if library.isActive(set) {
                        Button("停止临时启用") { library.deactivate(set) }
                    }
                    Button("临时启用") {
                        Task { await library.activate(set) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(memberFamilies.isEmpty || library.busy != nil)
                    .help("停用中 / 移动硬盘 / 压缩存放的字体，注册到这次登录（注销或重启后自动停用，文件不动）")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("字体").font(.headline)
                        Text("\(memberFamilies.count) 个家族").foregroundStyle(.secondary)
                        Spacer()
                        Button("添加字体…") { showPicker = true }
                    }
                    if memberFamilies.isEmpty {
                        Text("还没有字体。点「添加字体…」，或在「字体库」里右键 › 加入字体集。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(memberFamilies) { family in
                        HStack(spacing: 8) {
                            Text(family.displayName).lineLimit(1)
                            if let face = family.representative {
                                FontSampleText(face: face, text: face.coversCJK ? "永和九年 Aa" : "Aa Bb 0123", size: 16)
                                    .frame(maxWidth: 200, alignment: .leading)
                            }
                            Spacer()
                            ForEach(family.locations, id: \.self) { FontLocationBadge(location: $0) }
                            Button {
                                remove(family)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("从字体集里拿掉（字体本身不动）")
                        }
                        .padding(.vertical, 2)
                    }
                    let missing = library.missingNames(of: set)
                    if !missing.isEmpty {
                        Text("有 \(missing.count) 个字体找不到了（文件被删掉或移走）：\(missing.prefix(5).joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .glassCard(radius: 14)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("绑定项目文件夹").font(.headline)
                        Spacer()
                        Button("添加文件夹…", action: chooseFolder)
                    }
                    Text("在拾掇里打开这些文件夹（或里面的子文件夹）时：")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $modeRaw) {
                        Text("询问我").tag(FontSetBinding.Mode.ask.rawValue)
                        Text("自动启用").tag(FontSetBinding.Mode.auto.rawValue)
                        Text("不处理").tag(FontSetBinding.Mode.off.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    ForEach(set.boundFolders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(FileManager.default.displayName(atPath: folder))
                            Text(folder)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                library.unbind(set.id, folder: folder)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .glassCard(radius: 14)

                HStack {
                    Spacer()
                    Button("删除字体集…", role: .destructive) { confirmDelete = true }
                }
            }
            .padding(20)
        }
        .onAppear { name = set.name }
        .sheet(isPresented: $showPicker) {
            FontSetPicker(set: set)
        }
        .confirmationDialog("删除字体集「\(set.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                library.deactivate(set)
                library.deleteSet(set.id)
                onDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除这个字体集，里面的字体文件不动。")
        }
    }

    private func rename() {
        var updated = set
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != set.name else { return }
        updated.name = trimmed
        library.updateSet(updated)
    }

    private func remove(_ family: FontFamily) {
        var updated = set
        let names = Set(family.faces.map(\.postScriptName))
        updated.postScriptNames.removeAll { names.contains($0) }
        library.updateSet(updated)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "绑定")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { library.bind(set.id, folder: url) }
    }
}

/// 往字体集里加字体：搜索 + 勾选。
private struct FontSetPicker: View {
    @ObservedObject private var library = FontLibrary.shared
    @Environment(\.dismiss) private var dismiss
    let set: FontSet
    @State private var query = ""
    @State private var picked: Set<String> = []

    private var families: [FontFamily] {
        FontLibraryLogic.sorted(library.families.filter {
            !$0.locations.contains(.system) && FontLibraryLogic.matches($0, query: query)
        }, by: .name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加到「\(set.name)」").font(.title3.weight(.semibold))
            TextField("搜索字体（中文名、英文名、拼音首字母）", text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(families) { family in
                    Toggle(isOn: Binding(
                        get: { picked.contains(family.id) },
                        set: { on in if on { picked.insert(family.id) } else { picked.remove(family.id) } }
                    )) {
                        HStack {
                            Text(family.displayName)
                            Spacer()
                            ForEach(family.locations, id: \.self) { FontLocationBadge(location: $0) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 320)
            Text("系统字体一直都能用，不用加进字体集。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加（\(picked.count)）") {
                    var updated = set
                    for family in library.families where picked.contains(family.id) {
                        for face in family.faces where !face.isDamaged && !updated.postScriptNames.contains(face.postScriptName) {
                            updated.postScriptNames.append(face.postScriptName)
                        }
                    }
                    library.updateSet(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }
}

// MARK: - 清理页里的「字体」卡片 / 项目横幅

/// 清理页「你来决定」里的字体卡片：点进去在字体页的「问题字体」里挑（默认不勾、默认停用）。

// MARK: - 标记、授权说明

extension FontStyleClass {
    var title: String {
        switch self {
        case .serif: return String(localized: "衬线 / 宋体")
        case .sans: return String(localized: "无衬线 / 黑体")
        case .mono: return String(localized: "等宽")
        case .script: return String(localized: "手写 / 楷书")
        case .decorative: return String(localized: "装饰")
        case .other: return String(localized: "其他")
        }
    }
}

/// 「可商用 / 不可商用」小标签；没写授权说明、也没手动标的不显示。
struct FontCommercialBadge: View {
    let status: FontCommercialStatus
    /// 手动标的（不是从授权说明读的）。
    var manual = false

    var body: some View {
        switch status {
        case .yes: badge(String(localized: "可商用"), tint: .green)
        case .no: badge(String(localized: "不可商用"), tint: .red)
        case .unknown: EmptyView()
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
            .help(manual ? String(localized: "你手动标的") : String(localized: "按字体文件里写的授权说明判断，仅供参考，以字体厂商的授权为准"))
    }
}

/// 展开后最后一行：字体文件里写的授权说明。
private struct FontLicenseLine: View {
    let text: String
    let url: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("授权说明")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            if text.isEmpty && url.isEmpty {
                Text("字体文件里没有写")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(text.isEmpty ? url : text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(text)
                if let link = URL(string: url), !url.isEmpty, link.scheme?.hasPrefix("http") == true {
                    Link("打开授权网页", destination: link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

// MARK: - 对比

private struct FontCompareTab: View {
    @ObservedObject private var library = FontLibrary.shared
    @AppStorage("fonts.sampleText") private var sample = FontCoverage.defaultSample
    @AppStorage("fonts.compareSize") private var size = 40.0
    @AppStorage("fonts.compareOverlay") private var overlay = false

    /// 叠放时每款用的颜色（轮着用）。
    static let palette: [Color] = [.blue, .red, .green, .orange, .purple, .pink, .teal, .brown]

    var body: some View {
        let families = library.compareFamilies
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("对比用的文字", text: $sample)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $overlay) {
                    Text("并排").tag(false)
                    Text("叠放").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                Slider(value: $size, in: 14...160)
                    .frame(width: 140)
                Text("\(Int(size)) pt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Button("清空") { library.compareIDs = [] }
                    .disabled(families.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            if families.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("还没有要对比的字体")
                        .font(.headline)
                    Text("在「字体库」里选中几款点「对比所选」，或右键「加入对比」（最多 \(FontCompareLogic.maxCount) 款）。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if overlay {
                overlayView(families)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(families) { family in
                            row(family)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var text: String { sample.isEmpty ? FontCoverage.defaultSample : sample }

    private func row(_ family: FontFamily) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(family, color: nil)
            if let face = family.representative {
                FontSampleText(face: face, text: text, size: CGFloat(size), lines: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private func header(_ family: FontFamily, color: Color?) -> some View {
        HStack(spacing: 6) {
            if let color {
                Circle().fill(color).frame(width: 9, height: 9)
            }
            Text(family.displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if family.styleClass != .other {
                Text(family.styleClass.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FontCommercialBadge(status: library.commercialStatus(family), manual: library.mark(for: family).commercial != nil)
            Spacer(minLength: 4)
            Text(family.totalBytes.byteText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                library.removeFromCompare(family.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("移出对比")
        }
    }

    /// 叠放：每款一种颜色、半透明叠在同一个位置，看字面大小、基线、字重差多少。
    private func overlayView(_ families: [FontFamily]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                    if let face = family.representative {
                        FontSampleText(face: face, text: text, size: CGFloat(size), lines: 2,
                                       color: NSColor(Self.palette[index % Self.palette.count]).withAlphaComponent(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(families.enumerated()), id: \.element.id) { index, family in
                        header(family, color: Self.palette[index % Self.palette.count])
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 下载里的字体

private struct FontDownloadsTab: View {
    @ObservedObject private var library = FontLibrary.shared
    @State private var checked: Set<String> = []
    @AppStorage("fonts.trashAfterInstall") private var trashAfterInstall = false

    private var items: [FontDownloadItem] { library.downloadItems }
    private var newItems: [FontDownloadItem] { items.filter { !$0.alreadyInstalled } }
    private var installedItems: [FontDownloadItem] { items.filter(\.alreadyInstalled) }
    private var checkedNew: [FontDownloadItem] { newItems.filter { checked.contains($0.id) } }
    private var checkedInstalled: [FontDownloadItem] { installedItems.filter { checked.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("「下载」文件夹里（往下 \(FontDownloadsLogic.maxDepth) 层）的字体文件。安装 = 拷一份到 ~/Library/Fonts，可以撤销。",
                      systemImage: "arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    library.scanDownloads()
                } label: {
                    HStack(spacing: 6) {
                        if library.isScanningDownloads { ProgressView().controlSize(.small) }
                        Text("重新查找")
                    }
                }
                .disabled(library.isScanningDownloads)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
            if !library.hasScannedDownloads {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在查找下载里的字体…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("下载里没有字体文件（压缩包要先解压）")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !newItems.isEmpty {
                        Section {
                            ForEach(newItems) { row($0) }
                        } header: {
                            HStack {
                                Text("还没安装 · \(newItems.count) 个")
                                Spacer()
                                Button(checkedNew.count == newItems.count ? LocalizedStringKey("全不选") : LocalizedStringKey("全选")) {
                                    if checkedNew.count == newItems.count {
                                        newItems.forEach { checked.remove($0.id) }
                                    } else {
                                        newItems.forEach { checked.insert($0.id) }
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    if !installedItems.isEmpty {
                        Section("已经装过 · \(installedItems.count) 个（下载里这份可以清掉）") {
                            ForEach(installedItems) { row($0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("装好后把下载里的原文件移到废纸篓", isOn: $trashAfterInstall)
                    .toggleStyle(.checkbox)
                Spacer()
                if !checkedInstalled.isEmpty {
                    Button("把已装过的移到废纸篓（\(checkedInstalled.count)）") {
                        let list = checkedInstalled
                        list.forEach { checked.remove($0.id) }
                        library.trashDownloads(list)
                    }
                }
                Button("安装所选（\(checkedNew.count)）") {
                    let list = checkedNew
                    list.forEach { checked.remove($0.id) }
                    let trash = trashAfterInstall
                    Task { await library.install(list, trashOriginals: trash) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkedNew.isEmpty || library.busy != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .task { library.scanDownloadsIfNeeded() }
    }

    private func row(_ item: FontDownloadItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { checked.contains(item.id) },
                set: { on in if on { checked.insert(item.id) } else { checked.remove(item.id) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayFamily)
                        .font(.headline)
                        .lineLimit(1)
                    if item.coversCJK {
                        Text("中")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    }
                    FontCommercialBadge(status: FontLicenseLogic.status(hint: item.licenseHint, mark: FontMark()))
                    if item.alreadyInstalled {
                        Text("已安装")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(item.faces.count) 个样式 · \(item.fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 200, alignment: .leading)
            if let face = item.faces.first {
                FontSampleText(face: face, text: face.coversCJK ? "永和九年 Aa" : "Aa Bb 0123", size: 18)
                    .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
            }
            Spacer(minLength: 8)
            Text(item.size.byteText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .stableContextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }
}

struct FontsCleanupTile: View {
    @ObservedObject private var library = FontLibrary.shared

    var body: some View {
        CompactCleanupTile(
            symbol: "f.cursive", tint: .indigo, title: String(localized: "字体"),
            value: library.isScanning && !library.hasScanned ? String(localized: "扫描中…") : library.actionableIssueBytes.byteText,
            detail: library.hasScanned ? String(localized: "\(library.actionableIssueCount) 个") : "",
            reason: String(localized: "重复、旧版本和损坏的字体；默认是停用（不删除，随时可以启用）"),
            isNew: true
        )
    }
}

/// 打开绑定了字体集的项目文件夹时，页面顶上的小横幅。
struct FontProjectBannerView: View {
    @ObservedObject private var library = FontLibrary.shared
    @Environment(\.isActivePane) private var isActivePane

    var body: some View {
        if let banner = library.projectBanner, isActivePane {
            HStack(spacing: 10) {
                Image(systemName: "f.cursive")
                    .foregroundStyle(.indigo)
                Text(banner.text)
                    .font(.callout.weight(.medium))
                if banner.needsConfirm {
                    Button("启用") { library.confirmBanner() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button {
                    library.projectBanner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension Array where Element: Hashable {
    /// 去重，保留第一次出现的顺序。
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
