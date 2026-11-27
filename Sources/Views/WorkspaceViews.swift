import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 拾掇 Pro「工作区」的页面、侧边栏小节和设置面板。数据在 WorkspaceStore，纯逻辑在 WorkspaceLogic.swift。

// MARK: - 名字 / 颜色 / 图标

extension Workspace {
    var tint: Color {
        let colors = FolderPalette.colors
        let index = colors.indices.contains(colorIndex) ? colorIndex : WorkspaceLogic.defaultColorIndex
        return Color(nsColor: colors[min(index, colors.count - 1)].1)
    }
}

extension WorkspaceSourceKind {
    var title: String {
        switch self {
        case .local: return String(localized: "本地")
        case .desktop: return String(localized: "桌面")
        case .documents: return String(localized: "文稿")
        case .downloads: return String(localized: "下载")
        case .iCloud: return String(localized: "iCloud 云盘")
        case .external: return String(localized: "外接硬盘")
        }
    }

    var symbol: String {
        switch self {
        case .local: return "internaldrive"
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc"
        case .downloads: return "arrow.down"
        case .iCloud: return "icloud"
        case .external: return "externaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .local, .desktop: return Color(red: 0.40, green: 0.58, blue: 0.98)
        case .documents: return Color(red: 0.98, green: 0.62, blue: 0.25)
        case .downloads: return Color(red: 0.66, green: 0.52, blue: 0.96)
        case .iCloud: return Color(red: 0.25, green: 0.70, blue: 0.92)
        case .external: return Color(red: 0.50, green: 0.53, blue: 0.60)
        }
    }
}

extension WorkspaceFileKind {
    var title: String {
        switch self {
        case .image: return String(localized: "图片")
        case .document: return String(localized: "文稿")
        case .video: return String(localized: "视频")
        case .other: return String(localized: "其他")
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .document: return "doc.text"
        case .video: return "film"
        case .other: return "ellipsis"
        }
    }

    var tint: Color {
        switch self {
        case .image: return FileCategory.images.tint
        case .document: return FileCategory.documents.tint
        case .video: return FileCategory.videos.tint
        case .other: return Color(red: 0.96, green: 0.58, blue: 0.30)
        }
    }
}

enum WorkspaceSymbolNames {
    static func title(_ symbol: String) -> String {
        switch symbol {
        case "folder": return String(localized: "文件夹")
        case "briefcase": return String(localized: "公文包")
        case "paintpalette": return String(localized: "调色盘")
        case "camera": return String(localized: "相机")
        case "film": return String(localized: "影片")
        case "photo": return String(localized: "照片")
        case "doc.text": return String(localized: "文稿")
        case "book": return String(localized: "书")
        case "music.note": return String(localized: "音乐")
        case "shippingbox": return String(localized: "包装盒")
        case "hammer": return String(localized: "锤子")
        case "chart.bar": return String(localized: "图表")
        case "person.2": return String(localized: "客户")
        case "cart": return String(localized: "购物车")
        case "graduationcap": return String(localized: "学习")
        case "star": return String(localized: "星标")
        case "heart": return String(localized: "爱心")
        case "leaf": return String(localized: "叶子")
        case "airplane": return String(localized: "旅行")
        case "house": return String(localized: "家")
        default: return symbol
        }
    }
}

/// 改图标 / 改颜色的选择器（侧边栏右键、标题旁 ⌄ 菜单共用，菜单里显示成带勾的子菜单）。
struct WorkspaceStyleMenus: View {
    let id: UUID
    @ObservedObject private var workspaces = WorkspaceStore.shared

    var body: some View {
        if let workspace = workspaces.workspace(id) {
            Picker(selection: Binding(get: { workspace.symbol }, set: { workspaces.setSymbol(id, $0) })) {
                ForEach(WorkspaceLogic.symbols, id: \.self) { symbol in
                    Label(WorkspaceSymbolNames.title(symbol), systemImage: symbol).tag(symbol)
                }
            } label: {
                Text("修改图标")
            }
            Picker(selection: Binding(get: { workspace.colorIndex }, set: { workspaces.setColor(id, $0) })) {
                ForEach(Array(FolderPalette.colors.enumerated()), id: \.offset) { index, color in
                    Label {
                        Text(color.0)
                    } icon: {
                        Image(nsImage: FolderPalette.swatch(color.1))
                    }
                    .tag(index)
                }
            } label: {
                Text("修改颜色")
            }
        }
    }
}

// MARK: - 侧边栏

/// 侧边栏「工作区」：每个工作区一行（拖动排序、右键改名 / 图标 / 颜色 / 删除、把文件夹拖上来加成来源），最后一行「新建工作区」。
struct WorkspacesSidebarSection: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @ObservedObject private var appearance = AppearanceStore.shared

    var body: some View {
        CollapsibleSection("workspaces") {
            ForEach(workspaces.workspaces) { workspace in
                row(workspace)
            }
            .onMove { workspaces.move(fromOffsets: $0, toOffset: $1) }
            Button {
                if let id = workspaces.create() {
                    store.selection = .workspace(id)
                    workspaces.renamingInline = id
                }
            } label: {
                Label("新建工作区", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("新建一个工作区：把同一个项目的几个文件夹放在一起看")
        } header: {
            HStack(spacing: 6) {
                Text("工作区")
                ProBadge()
                    .opacity(license.isPro ? 0.55 : 1)
            }
        }
    }

    private func row(_ workspace: Workspace) -> some View {
        Label {
            Text(workspace.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: workspace.symbol)
                .foregroundStyle(appearance.settings.sidebarColorIcons ? workspace.tint : Color.secondary)
        }
        .tag(SidebarItem.workspace(workspace.id))
        .help(String(localized: "\(workspace.sources.count) 个来源；把文件夹拖到这里加进工作区（只记位置，不移动原文件）"))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FileDrop.load(providers) { urls in
                if let message = workspaces.addSources(urls, to: workspace.id) { store.showToast(message) }
            }
        }
        .stableContextMenu {
            Button("重命名…") { workspaces.promptRename(workspace.id) }
            WorkspaceStyleMenus(id: workspace.id)
            Divider()
            Button("删除工作区…", role: .destructive) {
                let id = workspace.id
                if workspaces.confirmDelete(id), store.selection == .workspace(id) { store.selection = .home }
            }
        }
    }
}

// MARK: - 页面

enum WorkspaceTab: Hashable, CaseIterable {
    case overview, folders, images, documents, videos, others

    var title: String {
        switch self {
        case .overview: return String(localized: "概览")
        case .folders: return String(localized: "workspace.tab.folders", defaultValue: "文件夹")
        case .images: return String(localized: "图片")
        case .documents: return String(localized: "文稿")
        case .videos: return String(localized: "视频")
        case .others: return String(localized: "其他")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.on.rectangle"
        case .folders: return "folder"
        case .images: return "photo"
        case .documents: return "doc"
        case .videos: return "film"
        case .others: return "ellipsis"
        }
    }

    var kind: WorkspaceFileKind? {
        switch self {
        case .images: return .image
        case .documents: return .document
        case .videos: return .video
        case .others: return .other
        case .overview, .folders: return nil
        }
    }

    static func tab(for kind: WorkspaceFileKind) -> WorkspaceTab {
        switch kind {
        case .image: return .images
        case .document: return .documents
        case .video: return .videos
        case .other: return .others
        }
    }

    func count(_ totals: WorkspaceTotals) -> Int {
        switch self {
        case .overview: return totals.fileCount
        case .folders: return totals.folderCount
        case .images: return totals.images
        case .documents: return totals.documents
        case .videos: return totals.videos
        case .others: return totals.others
        }
    }
}

/// 工作区页：标题 + 统计 + 分段标签；概览里是来源、最近文件、分类、快捷操作。没有来源时是添加引导。
struct WorkspaceView: View {
    let id: UUID
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var workspaces = WorkspaceStore.shared

    @State private var tab: WorkspaceTab = .overview
    @State private var selectedPath: String?
    @State private var previewURL: URL?
    @State private var editingName = false
    @State private var draftName = ""
    @State private var showSettings = false
    @State private var dropTargeted = false
    @FocusState private var nameFocused: Bool
    @FocusState private var gridFocused: Bool

    var body: some View {
        Group {
            if let workspace = workspaces.workspace(id) {
                page(workspace)
            } else {
                ContentUnavailableView("找不到这个工作区", systemImage: "questionmark.folder",
                                       description: Text("它可能已经被删除了。"))
            }
        }
        .navigationTitle("工作区")
        .onAppear {
            workspaces.refresh(id)
            if workspaces.renamingInline == id { beginRename() }
        }
        .onDisappear { workspaces.cancelScans(id) }
        .onChange(of: workspaces.renamingInline) {
            if workspaces.renamingInline == id { beginRename() }
        }
        .nativeQuickLook($previewURL, in: previewURL.map { [$0] } ?? [])
        .sheet(isPresented: $showSettings) {
            WorkspaceSettingsSheet(id: id) { deleted in
                if deleted { store.selection = .home }
            }
        }
    }

    // MARK: 整页

    private static let bottomAnchor = "workspace.bottom"

    private func page(_ workspace: Workspace) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(workspace)
                if workspace.sources.isEmpty {
                    emptyGuide(workspace)
                } else if !WorkspaceAccess.unlocked {
                    // 试用结束：来源和缓存都留着，重新解锁就回来。
                    ProLockedView(feature: WorkspaceAccess.feature)
                        .frame(minHeight: 360)
                } else {
                    WorkspaceTabBar(tab: $tab, totals: workspaces.totals(workspace))
                    if tab == .overview {
                        overview(workspace)
                    } else {
                        fileGrid(workspace)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPath = nil }
            )
            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchor)
        }
        .onAppear {
            // 截图用（--page=workspace-bottom）：滚到最下面，看分类和快捷操作。
            guard Demo.isOn, Demo.page == "workspace-bottom" else { return }
            for delay in [1.5, 3.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
        }
        .scrollContentBackground(.hidden)
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if previewURL != nil {
                previewURL = nil
                return .handled
            }
            guard let path = selectedPath else { return .ignored }
            preview(path, cloudOnly: isCloudOnly(path, in: workspace))
            return .handled
        }
        .onKeyPress(.escape) {
            if previewURL != nil {
                previewURL = nil
                return .handled
            }
            guard selectedPath != nil else { return .ignored }
            selectedPath = nil
            return .handled
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { urls in
                if let message = workspaces.addSources(urls, to: workspace.id) { store.showToast(message) }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 标题

    private func header(_ workspace: Workspace) -> some View {
        AdaptiveRow(spacing: 12, lineSpacing: 12, alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    title(workspace)
                    titleMenu(workspace)
                }
                if !workspace.sources.isEmpty {
                    statsLine(workspace)
                }
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                    Text("只记位置，不移动原文件")
                    if workspaces.onlineSources(workspace).count < workspace.sources.count && !workspace.sources.isEmpty {
                        Text(verbatim: "·")
                        Text("未连接的来源显示上次统计")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let notice = workspaces.readOnlyNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Button { addFolders(workspace) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("添加文件夹")
                        if !license.isPro && WorkspaceAccess.requiresPro { ProBadge() }
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("选几个文件夹加进这个工作区（只记位置，不移动原文件）")
                moreMenu(workspace)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func title(_ workspace: Workspace) -> some View {
        if editingName {
            TextField("工作区名称", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .focused($nameFocused)
                .frame(minWidth: 200, maxWidth: 460)
                .onSubmit { commitRename() }
                .onExitCommand { editingName = false }
                .onChange(of: nameFocused) {
                    if !nameFocused && editingName { commitRename() }
                }
        } else {
            Text(workspace.name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2) { beginRename() }
                .help("双击重命名")
        }
    }

    private func titleMenu(_ workspace: Workspace) -> some View {
        Menu {
            Button("重命名") { beginRename() }
            WorkspaceStyleMenus(id: workspace.id)
            Divider()
            Button("工作区设置…") { showSettings = true }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("重命名、修改图标、修改颜色、工作区设置")
        .accessibilityLabel("工作区菜单")
    }

    private func moreMenu(_ workspace: Workspace) -> some View {
        Menu {
            Button("重新统计") { workspaces.refresh(workspace.id, force: true) }
                .disabled(workspace.sources.isEmpty)
            Button("重命名…") { beginRename() }
            Button("工作区设置…") { showSettings = true }
            Divider()
            Button("删除工作区…", role: .destructive) {
                if workspaces.confirmDelete(workspace.id) { store.selection = .home }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // 菜单按钮会丢掉标签上的背景：底板画在菜单外面。
        .frame(width: 36, height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)).allowsHitTesting(false))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("更多")
    }

    private func statsLine(_ workspace: Workspace) -> some View {
        let totals = workspaces.totals(workspace)
        let scanning = workspaces.isScanning(workspace)
        return HStack(spacing: 6) {
            Text("\(totals.sources) 个来源")
            Text(verbatim: "·")
            if totals.fileCount == 0 && scanning {
                Text("统计中…")
            } else {
                if totals.truncated {
                    Text("至少 \(totals.fileCount.formatted()) 个文件")
                } else {
                    Text("\(totals.fileCount.formatted()) 个文件")
                }
                Text(verbatim: "·")
                Text(totals.bytes.byteText)
                if let date = totals.lastModified {
                    Text(verbatim: "·")
                    Text("\(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))修改")
                }
            }
            if scanning {
                ProgressView().controlSize(.mini)
                Button("停止") { workspaces.cancelScans(workspace.id) }
                    .buttonStyle(.link)
                    .help("停止统计（下次打开再继续）")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .monospacedDigit()
    }

    // MARK: 空引导

    private func emptyGuide(_ workspace: Workspace) -> some View {
        VStack(spacing: 16) {
            TintedIcon(symbol: "folder.badge.plus", tint: workspace.tint, size: 72)
            Text("添加文件夹，开始整理你的项目")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("把同一个项目散在桌面、iCloud 云盘、移动硬盘上的文件夹放进来，一眼看到有多少文件、最近改了什么。工作区只记住位置，不移动、不复制原文件。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
            Button { addFolders(workspace) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("添加文件夹…")
                    if !license.isPro && WorkspaceAccess.requiresPro { ProBadge() }
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("也可以把文件夹直接拖到这里，或拖到侧边栏的工作区上")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
        .glassCard(tint: workspace.tint, radius: 24)
    }

    // MARK: 概览

    @ViewBuilder
    private func overview(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "来源"), count: workspace.sources.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                ForEach(workspace.sources) { source in
                    sourceCard(source, in: workspace)
                }
            }
        }
        let recent = workspaces.recentFiles(workspace, limit: 12)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: String(localized: "最近文件"))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(recent) { pair in
                            fileTile(pair.entry, source: pair.source)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
            }
        }
        categories(workspace)
        quickActions(workspace)
    }

    private func sourceCard(_ source: WorkspaceSource, in workspace: Workspace) -> some View {
        let state = workspaces.state(source)
        let parent = workspaces.nested(workspace)[source.id]
        let denied = workspaces.denied.contains(source.id)
        return WorkspaceSourceCard(source: source, state: state, stats: workspaces.stats(source),
                                   scanning: workspaces.scanning.contains(source.id), insideOf: parent, denied: denied)
            .onTapGesture(count: 2) {
                if let path = state.path { store.goToRoot(path) }
            }
            .help(denied ? String(localized: "拾掇没有权限读取这个文件夹，数字是上次的。到 系统设置 › 隐私与安全性 › 文件与文件夹（或「完全磁盘访问权限」）里允许拾掇，再重新统计。")
                  : parent.map { String(localized: "这个文件夹在「\($0)」里面，统计和打包时不重复计算") } ?? sourceHelp(source, state: state))
            .stableContextMenu {
                Button("在拾掇中打开") { if let path = state.path { store.goToRoot(path) } }
                    .disabled(!state.isOnline)
                Button("在访达中显示") {
                    if let path = state.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .disabled(!state.isOnline)
                Button("重新统计") { workspaces.scan(source) }
                    .disabled(!state.isOnline)
                if denied {
                    Button("打开隐私设置…") { WorkspaceStore.openPrivacySettings() }
                }
                Divider()
                Button("从工作区移除（文件夹不动）") { workspaces.removeSource(source.id, from: workspace.id) }
            }
    }

    private func sourceHelp(_ source: WorkspaceSource, state: WorkspaceSourceAvailability) -> String {
        switch state {
        case .online(let path): return path
        case .offline(let name): return String(localized: "硬盘「\(name)」没有连接。记录和上次的统计都还在，接上后自动恢复。")
        case .missing: return String(localized: "找不到这个文件夹了：\(source.path)")
        }
    }

    // MARK: 文件格子（最近文件、分段标签）

    private func fileTile(_ entry: WorkspaceFileEntry, source: WorkspaceSource) -> some View {
        let url = URL(fileURLWithPath: entry.path)
        return WorkspaceFileTile(entry: entry, sourceName: source.name, sourceSymbol: source.kind.symbol,
                                 selected: selectedPath == entry.path)
            .onTapGesture(count: 2) { open(entry) }
            .onTapGesture {
                selectedPath = entry.path
                gridFocused = true
                if previewURL != nil, !entry.cloudOnly { previewURL = url }
            }
            .stableContextMenu {
                if !entry.isFolder {
                    Button("快速查看") { preview(entry.path, cloudOnly: entry.cloudOnly) }
                        .disabled(entry.cloudOnly)
                }
                Button("打开") { open(entry) }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("放进暂存架") {
                    let added = ShelfStore.shared.add([url])
                    store.showToast(added > 0 ? String(localized: "已加入暂存架：\(added) 个") : String(localized: "已经在暂存架上了"))
                }
            }
            .onDrag { InAppDrag.copyOnlyProvider(url) }
            .help(entry.cloudOnly ? String(localized: "\(entry.path)（只在 iCloud 云端）") : entry.path)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(entry) }
    }

    private func open(_ entry: WorkspaceFileEntry) {
        let url = URL(fileURLWithPath: entry.path)
        if entry.isFolder {
            store.goToRoot(entry.path)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func preview(_ path: String, cloudOnly: Bool) {
        if cloudOnly {
            store.showToast(String(localized: "这个文件只在 iCloud 云端，没有下载，先不预览"))
            return
        }
        previewURL = URL(fileURLWithPath: path)
    }

    private func isCloudOnly(_ path: String, in workspace: Workspace) -> Bool {
        let pairs = workspaces.recentFiles(workspace, limit: 50) + (tab.kind.map { workspaces.files(workspace, kind: $0) } ?? [])
        return pairs.first { $0.entry.path == path }?.entry.cloudOnly ?? false
    }

    @ViewBuilder
    private func fileGrid(_ workspace: Workspace) -> some View {
        let list = workspaces.files(workspace, kind: tab.kind)
        let offline = workspace.sources.filter { !workspaces.state($0).isOnline }
        VStack(alignment: .leading, spacing: 12) {
            if !offline.isEmpty {
                Label(String(localized: "\(offline.map(\.name).joined(separator: "、")) 没有连接，这里没有列出它的文件"),
                      systemImage: "externaldrive.badge.xmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if list.isEmpty {
                HStack(spacing: 10) {
                    if workspaces.isScanning(workspace) {
                        ProgressView().controlSize(.small)
                        Text("正在读取…")
                    } else {
                        Text(tab == .folders ? String(localized: "来源里没有子文件夹") : String(localized: "没有这一类文件"))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 18) {
                    ForEach(list) { pair in
                        fileTile(pair.entry, source: pair.source)
                    }
                }
                if list.count >= 300 {
                    Text("只显示最近修改的 300 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 分类

    private func categories(_ workspace: Workspace) -> some View {
        let totals = workspaces.totals(workspace)
        let recent = workspaces.recentFiles(workspace, limit: 60)
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "workspace.section.categories", defaultValue: "分类"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 12) {
                ForEach(WorkspaceFileKind.allCases, id: \.self) { kind in
                    Button { tab = WorkspaceTab.tab(for: kind) } label: {
                        WorkspaceCategoryTile(kind: kind, count: totals.count(kind),
                                              previews: previews(kind, workspace: workspace, recent: recent))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 分类卡片上斜叠的三张：只用本机有的文件（不为了缩略图去下载云端文件）。
    private func previews(_ kind: WorkspaceFileKind, workspace: Workspace,
                          recent: [WorkspaceFileRow]) -> [FileItem] {
        let live = workspaces.files(workspace, kind: kind, limit: 6).map(\.entry)
        let pool = live.isEmpty ? recent.map(\.entry).filter { $0.kind == kind } : live
        return pool.filter { !$0.cloudOnly }.prefix(3).compactMap { FileItem(url: URL(fileURLWithPath: $0.path)) }
    }

    // MARK: 快捷操作

    private func quickActions(_ workspace: Workspace) -> some View {
        let online = workspaces.onlineSources(workspace)
        let none = online.isEmpty
        let offlineReason = String(localized: "来源都没有连接（硬盘没接上或文件夹找不到了），接上后再试")
        let zipping = workspaces.zipping == workspace.id
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: String(localized: "快捷操作"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                actionButton(WorkspaceActionTile(icon: .app("/System/Library/CoreServices/Finder.app"),
                                                 title: String(localized: "在访达中打开全部"), disabled: none),
                             help: none ? offlineReason : String(localized: "每个连接着的来源开一个访达窗口")) {
                    openAllInFinder(workspace)
                }
                actionButton(WorkspaceActionTile(icon: .symbol("square.stack.3d.up.fill", Color(red: 0.62, green: 0.45, blue: 0.95)),
                                                 title: String(localized: "全部放进暂存架"), disabled: none),
                             help: none ? offlineReason : String(localized: "把来源文件夹放上暂存架（只记位置，不复制）")) {
                    putAllOnShelf(workspace)
                }
                actionButton(WorkspaceActionTile(icon: .symbol("doc.zipper", Color(red: 0.96, green: 0.62, blue: 0.20)),
                                                 title: zipping ? String(localized: "正在打包…点按取消") : String(localized: "打包成 ZIP"),
                                                 disabled: none && !zipping, busy: zipping),
                             help: none ? offlineReason : String(localized: "打成一个 ZIP 放进「下载」，同名不覆盖")) {
                    if zipping { workspaces.cancelZip() } else { zip(workspace) }
                }
                .disabled(workspaces.zipping != nil && !zipping)
                actionButton(WorkspaceActionTile(icon: .symbol("folder.badge.plus", Color(red: 0.98, green: 0.62, blue: 0.22)),
                                                 title: String(localized: "新建文件夹"), disabled: none),
                             help: none ? offlineReason : String(localized: "在选中的来源里新建一个文件夹")) {
                    chooseSource(workspace, title: String(localized: "在哪个来源里新建文件夹？")) { newFolder(in: $0) }
                }
                actionButton(WorkspaceActionTile(icon: .app("/System/Applications/Utilities/Terminal.app"),
                                                 title: String(localized: "在终端打开"), disabled: none),
                             help: none ? offlineReason : String(localized: "在终端里打开选中的来源")) {
                    chooseSource(workspace, title: String(localized: "在终端打开哪个来源？")) { source in
                        ExternalApps.openInTerminal([(path: source.path, isDirectory: true)])
                    }
                }
            }
            if online.count < workspace.sources.count {
                Label("没连接的来源不参与快捷操作", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionButton(_ tile: WorkspaceActionTile, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tile }
            .buttonStyle(.plain)
            .disabled(tile.disabled)
            .help(help)
    }

    // MARK: 动作

    private func addFolders(_ workspace: Workspace) {
        if let message = workspaces.chooseAndAddSources(to: workspace.id) { store.showToast(message) }
    }

    private func beginRename() {
        guard let workspace = workspaces.workspace(id) else { return }
        workspaces.renamingInline = nil
        draftName = workspace.name
        editingName = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard editingName else { return }
        editingName = false
        workspaces.rename(id, to: draftName)
    }

    private func openAllInFinder(_ workspace: Workspace) {
        guard WorkspaceAccess.require() else { return }
        let online = workspaces.onlineSources(workspace)
        guard !online.isEmpty else { return }
        if online.count > 3 {
            let ok = WorkspaceConfirm.ask(
                title: String(localized: "在访达中打开 \(online.count) 个窗口？"),
                detail: String(localized: "每个来源开一个访达窗口。"),
                confirm: String(localized: "全部打开"))
            guard ok else { return }
        }
        for item in online {
            _ = NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path)
        }
    }

    private func putAllOnShelf(_ workspace: Workspace) {
        guard WorkspaceAccess.require() else { return }
        let online = workspaces.onlineSources(workspace)
        guard !online.isEmpty else { return }
        let stats = WorkspaceLogic.totals(online.map { workspaces.stats($0.source) })
        let ok = WorkspaceConfirm.ask(
            title: String(localized: "把 \(online.count) 个来源文件夹放进暂存架？"),
            detail: String(localized: "共 \(stats.fileCount.formatted()) 个文件，\(stats.bytes.byteText)。暂存架只记位置，不复制文件。"),
            confirm: String(localized: "放进暂存架"))
        guard ok else { return }
        let added = ShelfStore.shared.add(online.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
        store.showToast(added > 0 ? String(localized: "已加入暂存架：\(added) 个") : String(localized: "已经在暂存架上了"))
    }

    private func zip(_ workspace: Workspace) {
        guard WorkspaceAccess.require() else { return }
        let online = workspaces.zipSources(workspace)
        guard !online.isEmpty else { return }
        var files = 0
        var bytes: Int64 = 0
        var cloud = 0
        for item in online {
            if let result = workspaces.live[item.source.id] {
                files += result.localFileCount
                bytes += result.localBytes
                cloud += result.stats.cloudOnly
            } else if let stats = workspaces.stats(item.source) {
                files += stats.fileCount - stats.cloudOnly
                bytes += max(stats.bytes - stats.cloudBytes, 0)
                cloud += stats.cloudOnly
            }
        }
        // 先看剩余空间：不够就不开始（别把启动盘写满），让用户换个位置。
        guard let folder = zipFolder(needed: bytes) else { return }
        let folderName = FileManager.default.displayName(atPath: folder.path)
        var detail = String(localized: "约 \(files.formatted()) 个文件，\(bytes.byteText)（压缩前）。ZIP 放进「\(folderName)」，已有同名的不会被覆盖，会自动加编号。")
        detail += "\n" + String(localized: "隐藏文件（名字以「.」开头的）不打包。")
        if cloud > 0 { detail += "\n" + String(localized: "只在云端的 \(cloud) 个文件会跳过，不会下载。") }
        if online.count < workspace.sources.count { detail += "\n" + String(localized: "没连接的来源不打包。") }
        let ok = WorkspaceConfirm.ask(title: String(localized: "把「\(workspace.name)」打包成 ZIP？"), detail: detail,
                                      confirm: String(localized: "打包"))
        guard ok else { return }
        workspaces.zip(workspace.id, to: folder) { text, isError in
            if isError { store.alertMessage = text } else { store.showToast(text) }
        }
    }

    /// 打包放哪：默认「下载」；那块磁盘剩余空间不够（压缩前大小 + 2 GB 余量）时提示，让用户换一个位置。
    private func zipFolder(needed: Int64) -> URL? {
        var folder = WorkspaceStore.defaultZipFolder
        while true {
            let available = WorkspaceZip.availableCapacity(folder)
            if WorkspaceZip.hasRoom(needed: needed, available: available) { return folder }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "「\(FileManager.default.displayName(atPath: folder.path))」所在的磁盘空间不够")
            alert.informativeText = String(localized: "打包大约需要 \((needed + WorkspaceZip.reserveBytes).byteText)（含余量），这块磁盘只剩 \((available ?? 0).byteText)。可以换一个空间够的位置，比如外接硬盘。")
            alert.addButton(withTitle: String(localized: "选择其他位置…"))
            alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "放在这里")
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            folder = url
        }
    }

    /// 只有一个连着的来源时直接用它；有几个时弹出菜单选（没连接的显示成灰的，带原因）。
    private func chooseSource(_ workspace: Workspace, title: String, then action: @escaping (WorkspaceSource) -> Void) {
        guard WorkspaceAccess.require() else { return }
        let online = workspaces.onlineSources(workspace)
        if online.count == 1, workspace.sources.count == 1 {
            var source = online[0].source
            source.path = online[0].path
            action(source)
            return
        }
        var items: [WorkspacePopupMenu.Item] = []
        for source in workspace.sources {
            let state = workspaces.state(source)
            switch state {
            case .online(let path):
                var resolved = source
                resolved.path = path
                items.append(.init(title: source.name, enabled: true) { action(resolved) })
            case .offline:
                items.append(.init(title: String(localized: "\(source.name)（硬盘未连接）"), enabled: false) {})
            case .missing:
                items.append(.init(title: String(localized: "\(source.name)（找不到了）"), enabled: false) {})
            }
        }
        WorkspacePopupMenu.show(title: title, items: items)
    }

    private func newFolder(in source: WorkspaceSource) {
        let alert = NSAlert()
        alert.messageText = String(localized: "在「\(source.name)」里新建文件夹")
        let field = NSTextField(string: String(localized: "未命名文件夹"))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "新建"))
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        if name.isEmpty || name.hasPrefix(".") { name = String(localized: "未命名文件夹") }
        let parent = URL(fileURLWithPath: source.path, isDirectory: true)
        let target = WorkspaceLogic.uniqueURL(for: name, in: parent)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            store.showToast(String(localized: "已在「\(source.name)」里新建「\(target.lastPathComponent)」"))
            workspaces.scan(source)
        } catch {
            store.alertMessage = error.localizedDescription
        }
    }
}

// MARK: - 分段标签

struct WorkspaceTabBar: View {
    @Binding var tab: WorkspaceTab
    let totals: WorkspaceTotals
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showIcons: true)
            bar(showIcons: false)
            ScrollView(.horizontal, showsIndicators: false) {
                bar(showIcons: false)
                    .fixedSize()
            }
        }
    }

    private func bar(showIcons: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(WorkspaceTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    HStack(spacing: 8) {
                        if showIcons {
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .medium))
                        }
                        Text(item.title)
                            .font(.callout.weight(tab == item ? .semibold : .medium))
                            .lineLimit(1)
                        Text(item.count(totals).formatted())
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(scheme == .dark ? 0.12 : 0.85))
                                .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 4, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(5)
        .glassCard(radius: 16)
    }
}

// MARK: - 卡片

struct WorkspaceSourceCard: View {
    let source: WorkspaceSource
    let state: WorkspaceSourceAvailability
    let stats: WorkspaceSourceStats?
    let scanning: Bool
    /// 落在另一个来源里面（统计不重复算）：那个来源的名字。
    var insideOf: String?
    /// 没有权限读取（系统隐私权限没给）：不是「0 个文件」。
    var denied = false

    private var dimmed: Bool { !state.isOnline }

    private var countLine: String {
        guard let stats else {
            if denied { return String(localized: "没有权限读取") }
            return scanning ? String(localized: "统计中…") : String(localized: "还没有统计")
        }
        let partial = stats.truncated || stats.cloudFolders > 0 || stats.unreadableFolders > 0
        let count = partial ? String(localized: "至少 \(stats.fileCount.formatted()) 个") : String(localized: "\(stats.fileCount.formatted()) 个")
        var line = count + " · " + stats.bytes.byteText
        if stats.cloudFolders > 0 { line += " · " + String(localized: "部分在云端") }
        if stats.unreadableFolders > 0 { line += " · " + String(localized: "部分没有权限") }
        return line
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .interpolation(.high)
                .frame(width: 54, height: 54)
                .saturation(dimmed ? 0 : 1)
                .opacity(dimmed ? 0.65 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label(source.kind.title, systemImage: source.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(countLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            badge
                .padding(10)
        }
        .glassCard(tint: dimmed ? .clear : source.kind.tint, radius: 18, interactive: true)
        .opacity(dimmed ? 0.8 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .offline:
            statusPill(String(localized: "硬盘未连接"))
        case .missing:
            statusPill(String(localized: "找不到了"))
        case .online:
            if scanning {
                ProgressView().controlSize(.mini)
            } else if denied {
                statusPill(String(localized: "没有权限"))
            } else if let insideOf {
                statusPill(String(localized: "已包含在「\(insideOf)」里"))
            }
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
    }
}

struct WorkspaceFileTile: View {
    let entry: WorkspaceFileEntry
    let sourceName: String
    let sourceSymbol: String
    var selected = false

    private static let width: CGFloat = 140
    private var width: CGFloat { Self.width }

    var body: some View {
        let url = URL(fileURLWithPath: entry.path)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if entry.cloudOnly {
                    // 只在云端：用类型图标，不取缩略图（取缩略图可能触发下载）。
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05))
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
                            .resizable()
                            .frame(width: 56, height: 56)
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                } else {
                    ThumbnailView(url: url, size: width, fill: !entry.isFolder, modified: entry.modified, isFolder: entry.isFolder)
                }
            }
            .frame(width: width, height: 104)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .quickLookSource(url)
            Text(entry.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width, alignment: .leading)
            Label(sourceName, systemImage: sourceSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// 分类卡片：和首页「资料库」卡片同一个样子（左边彩色图标和数量，右边三张斜叠的缩略图）。
struct WorkspaceCategoryTile: View {
    let kind: WorkspaceFileKind
    let count: Int
    let previews: [FileItem]

    var body: some View {
        HStack(spacing: 14) {
            TintedIcon(symbol: kind.symbol, tint: kind.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(count.formatted()) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            FannedThumbnails(items: previews, total: count)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .glassCard(tint: kind.tint, radius: 18, interactive: true)
    }
}

struct WorkspaceActionTile: View {
    enum Icon {
        case app(String)
        case symbol(String, Color)
    }

    let icon: Icon
    let title: String
    var disabled = false
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    switch icon {
                    case .app(let path):
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .interpolation(.high)
                    case .symbol(let name, let tint):
                        Image(systemName: name)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tint)
                    }
                }
            }
            .frame(width: 30, height: 30)
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .glassCard(radius: 14, interactive: !disabled)
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - 确认 / 选来源

enum WorkspaceConfirm {
    /// 批量操作前的确认框。
    @MainActor
    static func ask(title: String, detail: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// 在鼠标位置弹一个小菜单（快捷操作里选来源）。
@MainActor
enum WorkspacePopupMenu {
    struct Item {
        let title: String
        let enabled: Bool
        let action: () -> Void
    }

    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    static func show(title: String, items: [Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for item in items {
            let target = Target(item.action)
            let menuItem = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = target
            menuItem.isEnabled = item.enabled
            menuItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - 工作区设置

/// 轻量的设置面板：名称、颜色、图标、来源列表（移除只删引用），删除工作区。
struct WorkspaceSettingsSheet: View {
    let id: UUID
    var onClose: (Bool) -> Void = { _ in }
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("工作区设置")
                .font(.title3.weight(.semibold))
            if let workspace = workspaces.workspace(id) {
                form(workspace)
            }
            HStack {
                Button("删除工作区…", role: .destructive) {
                    if workspaces.confirmDelete(id) {
                        dismiss()
                        onClose(true)
                    }
                }
                Spacer()
                Button("完成") {
                    workspaces.rename(id, to: name)
                    dismiss()
                    onClose(false)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { name = workspaces.workspace(id)?.name ?? "" }
    }

    @ViewBuilder
    private func form(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("名称").font(.callout.weight(.medium))
            TextField("工作区名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { workspaces.rename(id, to: name) }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("颜色").font(.callout.weight(.medium))
            HStack(spacing: 8) {
                ForEach(Array(FolderPalette.colors.enumerated()), id: \.offset) { index, color in
                    Button { workspaces.setColor(id, index) } label: {
                        Circle()
                            .fill(Color(nsColor: color.1))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(workspace.colorIndex == index ? 0.8 : 0.15),
                                                           lineWidth: workspace.colorIndex == index ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(color.0)
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("图标").font(.callout.weight(.medium))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 10), alignment: .leading, spacing: 6) {
                ForEach(WorkspaceLogic.symbols, id: \.self) { symbol in
                    Button { workspaces.setSymbol(id, symbol) } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(workspace.symbol == symbol ? workspace.tint : Color.secondary)
                            .frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(workspace.symbol == symbol ? workspace.tint.opacity(0.18) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(WorkspaceSymbolNames.title(symbol))
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("来源").font(.callout.weight(.medium))
            if workspace.sources.isEmpty {
                Text("还没有来源")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(workspace.sources) { source in
                HStack(spacing: 8) {
                    Image(systemName: source.kind.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name).lineLimit(1)
                        Text(stateText(source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("移除") { workspaces.removeSource(source.id, from: id) }
                        .help("只从工作区移除，文件夹和里面的文件不动")
                }
            }
            Text("移除来源、删除工作区都只删记录，原来的文件夹和文件不会动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stateText(_ source: WorkspaceSource) -> String {
        switch workspaces.state(source) {
        case .online(let path): return path
        case .offline(let name): return String(localized: "硬盘「\(name)」未连接")
        case .missing: return String(localized: "找不到了：\(source.path)")
        }
    }
}
