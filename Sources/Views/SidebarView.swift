import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cleanup: CleanupScanner
    @EnvironmentObject private var duplicates: DuplicateScanner
    @EnvironmentObject private var chat: ChatFilesStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var shelf = ShelfStore.shared
    @ObservedObject private var reminders = ReminderStore.shared
    @ObservedObject private var customTags = CustomTagStore.shared
    @State private var shelfTargeted = false

    /// 常用位置，和访达侧边栏一样。
    private struct Location: Identifiable {
        let name: String
        let symbol: String
        let path: String
        let colors: [Color]
        var id: String { path }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    private var locations: [Location] {
        // 路径和 LibraryStore.builtInLocationPaths 保持一致。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Location(name: String(localized: "桌面"), symbol: "menubar.dock.rectangle", path: home + "/Desktop",
                     colors: [Self.rgb(0.40, 0.72, 1.00), Self.rgb(0.16, 0.47, 0.96)]),
            Location(name: String(localized: "文稿"), symbol: "doc.text.fill", path: home + "/Documents",
                     colors: [Self.rgb(1.00, 0.74, 0.30), Self.rgb(0.98, 0.52, 0.12)]),
            Location(name: String(localized: "下载"), symbol: "arrow.down", path: home + "/Downloads",
                     colors: [Self.rgb(0.40, 0.86, 0.50), Self.rgb(0.13, 0.66, 0.33)]),
            Location(name: String(localized: "sidebar.pictures", defaultValue: "图片"), symbol: "photo.fill", path: home + "/Pictures",
                     colors: [Self.rgb(1.00, 0.52, 0.66), Self.rgb(0.93, 0.27, 0.45)]),
            // 和资料库里的「全部视频」一样叫「视频」（不再「视频」「影片」两种写法）。
            Location(name: String(localized: "视频"), symbol: "film.fill", path: home + "/Movies",
                     colors: [Self.rgb(0.70, 0.55, 1.00), Self.rgb(0.47, 0.31, 0.92)]),
            Location(name: String(localized: "音乐"), symbol: "music.note", path: home + "/Music",
                     colors: [Self.rgb(1.00, 0.45, 0.45), Self.rgb(0.90, 0.20, 0.30)]),
        ]
    }

    /// 「所有标签…」展开时也列出没用过的颜色标签。
    @AppStorage("sidebar.showAllTags") private var showAllTags = false

    /// 侧边栏里列出的颜色标签：用过的、正在看的；展开「所有标签…」时列出全部。
    private var shownColorTags: [FinderTag] {
        FinderTag.colorTags.filter { tag in
            showAllTags || store.usedTags.contains(tag.name) || store.selection == .tag(tag.name)
        }
    }

    private var hiddenColorTagCount: Int {
        FinderTag.colorTags.count - shownColorTags.count
    }

    var body: some View {
        List(selection: $store.selection) {
            Label("首页", systemImage: "house")
                .tag(SidebarItem.home)

            Label("暂存架", systemImage: "tray.full")
                .badge(shelf.isEmpty ? nil : Text("\(shelf.count)"))
                .tag(SidebarItem.shelf)
                .help("把文件拖到这里，暂时放一下")
                .onDrop(of: [.fileURL], isTargeted: $shelfTargeted) { providers in
                    FileDrop.load(providers) { urls in
                        let added = shelf.add(urls)
                        if added > 0 { store.showToast(String(localized: "已加入暂存架：\(added) 个")) }
                    }
                }

            HStack {
                Label("提醒", systemImage: "alarm")
                Spacer()
                if reminders.count > 0 {
                    Text("\(reminders.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProBadge()
                    .opacity(license.isPro ? 0.55 : 1)
            }
            .tag(SidebarItem.reminders)

            HStack {
                Label("文件夹墙", systemImage: "square.grid.2x2")
                Spacer()
                if !store.pinnedFolders.isEmpty {
                    Text("\(store.pinnedFolders.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if ProFeature.folderWall.requiresPro {
                    ProBadge()
                        .opacity(license.isPro ? 0.55 : 1)
                }
            }
            .tag(SidebarItem.folderWall)
            .help("常用的文件夹放在一面卡片墙上，一眼看到里面有什么")

            CollapsibleSection("library", title: "资料库") {
                ForEach(FileCategory.allCases) { category in
                    Label {
                        Text(category.libraryTitle)
                    } icon: {
                        Image(systemName: category.symbol)
                            .foregroundStyle(category.tint)
                    }
                    .badge(store.totals[category].map { Text("\($0.count)") })
                    .tag(SidebarItem.category(category))
                    .help(category == .recents ? "" : String(localized: "整台 Mac 里所有的\(category.title)（按类型搜出来的，不只是某个文件夹）"))
                }
            }

            CollapsibleSection("smart", title: "智能文件夹") {
                // 和其他行一样用灰色计数（以前是红底白字，看起来像报错）。
                Label("大文件", systemImage: "externaldrive")
                    .badge(store.largeFileCount > 0 ? Text("\(store.largeFileCount)") : nil)
                    .tag(SidebarItem.largeFiles)
                    .help("200 MB 以上的文件")
                Label("截图", systemImage: "camera.viewfinder")
                    .tag(SidebarItem.screenshots)
                Label("下载来源", systemImage: "arrow.down.circle")
                    .badge(store.sourceGroups.isEmpty ? nil : Text("\(store.sourceGroups.count)"))
                    .tag(SidebarItem.downloads)
            }

            SavedSearchesSidebarSection()

            CollapsibleSection("organize", title: "整理") {
                Label("清理", systemImage: "sparkles")
                    .badge(cleanup.totalBytes > 0 ? Text(cleanup.totalBytes.byteText).foregroundColor(.green) : nil)
                    .tag(SidebarItem.cleanup)
                // 重复文件和相似照片是同一个页面（页内切换），侧边栏只占一行。
                Label("重复与相似", systemImage: "doc.on.doc")
                    .badge(duplicates.hasScanned && duplicates.reclaimable > 0 ? Text(duplicates.reclaimable.byteText).foregroundColor(.green) : nil)
                    .tag(duplicatesRow)
                    .help("完全相同的副本，以及看起来差不多的照片")
                Label("空间占用图", systemImage: "square.grid.3x3.square")
                    .tag(SidebarItem.storageMap)
                Label("清理记录", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.cleanupHistory)
                    .help("30 天内移到废纸篓或搬走的文件，可以放回原处")
                HStack {
                    Label("自动整理", systemImage: "wand.and.stars")
                    Spacer()
                    ProBadge()
                        .opacity(license.isPro ? 0.55 : 1)
                }
                .tag(SidebarItem.autoOrganize)
            }

            if !chat.installedApps.isEmpty {
                CollapsibleSection("chat", title: "聊天文件") {
                    ForEach(chat.installedApps) { app in
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(systemName: app.symbol)
                                .foregroundStyle(app == .wechat ? Color.green : Color.blue)
                        }
                        .badge(chat.hasScanned && chat.bytes(app) > 0 ? Text(chat.bytes(app).byteText) : nil)
                        .tag(SidebarItem.chat(app))
                    }
                }
            }

            CollapsibleSection("locations", title: "位置") {
                ForEach(locations) { location in
                    Label {
                        Text(location.name)
                    } icon: {
                        BadgeIcon(symbol: location.symbol, colors: location.colors)
                    }
                    .help(location.path)
                    .tag(SidebarItem.pinned(location.path))
                    // 在子文件夹里再点一次这一行：回到根目录。
                    .simultaneousGesture(TapGesture().onEnded { store.reselect(.pinned(location.path)) })
                }
            }

            VolumesSidebarSection()

            CollapsibleSection("tags") {
                ForEach(shownColorTags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        tagDot(tag.color)
                    }
                    .tag(SidebarItem.tag(tag.name))
                }
                ForEach(customTags.tags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        tagDot(FinderTag.color(tag.color))
                    }
                    .tag(SidebarItem.tag(tag.name))
                    .contextMenu {
                        Button("重命名…") { Task { await TagSync.rename(tag.name, store: store) } }
                        Button("改颜色…") { Task { await TagSync.recolor(tag.name, store: store) } }
                        Divider()
                        Button("从侧边栏移除（文件上的标签保留）") { customTags.remove(tag.name) }
                        Button("删除标签（同时从文件上去掉）…", role: .destructive) {
                            Task { await TagSync.delete(tag.name, store: store) }
                        }
                        Divider()
                        importFinderTagsButton
                    }
                }
                if showAllTags || hiddenColorTagCount > 0 {
                    Button {
                        showAllTags.toggle()
                    } label: {
                        Label(showAllTags ? String(localized: "只显示用过的标签") : String(localized: "所有标签…"),
                              systemImage: showAllTags ? "chevron.up.circle" : "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("没打在任何文件上的颜色标签收在这里")
                }
                Button {
                    switch CustomTagStore.promptNewOrImport() {
                    case .tag(let name, let color):
                        Task { await TagSync.addOrRecolor(name, color: color, store: store) }
                    case .importFinder:
                        Task { await TagSync.importFinderTags(store: store) }
                    case .cancel:
                        break
                    }
                } label: {
                    Label("新建标签…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .contextMenu { importFinderTagsButton }
            } header: {
                Text("标签")
                    .contextMenu { importFinderTagsButton }
            }

            // 以前这里还有一组「固定文件夹」：和「文件夹墙」是同一份数据，现在只留文件夹墙这一个入口。
        }
        .listStyle(.sidebar)
        .modifier(SavedSearchRenameAlert())
    }

    /// 正在看相似照片时，侧边栏也选中「重复与相似」这一行。
    private var duplicatesRow: SidebarItem {
        store.selection == .similarPhotos ? .similarPhotos : .duplicates
    }

    private func tagDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
            .frame(width: 20)
    }

    /// 「导入访达标签…」：把文件上已经有的标签（访达里建的）加进侧边栏。
    private var importFinderTagsButton: some View {
        Button("导入访达标签…") { Task { await TagSync.importFinderTags(store: store) } }
    }
}

// MARK: - 可折叠的小节

/// 侧边栏的小节都能折叠（点小标题右边的箭头），每个小节的折叠状态单独记在 UserDefaults 里。
struct CollapsibleSection<Content: View, Header: View>: View {
    private let content: Content
    private let header: Header
    @AppStorage private var collapsed: Bool

    init(_ id: String, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content()
        self.header = header()
        _collapsed = AppStorage(wrappedValue: false, CollapsibleSection.key(id))
    }

    static func key(_ id: String) -> String { "sidebar.collapsed." + id }

    var body: some View {
        Section(isExpanded: Binding(get: { !collapsed }, set: { collapsed = !$0 })) {
            content
        } header: {
            header
        }
    }
}

extension CollapsibleSection where Header == Text {
    init(_ id: String, title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(id, content: content) { Text(title) }
    }
}
