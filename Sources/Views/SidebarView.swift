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
            Location(name: String(localized: "sidebar.movies", defaultValue: "影片"), symbol: "film.fill", path: home + "/Movies",
                     colors: [Self.rgb(0.70, 0.55, 1.00), Self.rgb(0.47, 0.31, 0.92)]),
            Location(name: String(localized: "音乐"), symbol: "music.note", path: home + "/Music",
                     colors: [Self.rgb(1.00, 0.45, 0.45), Self.rgb(0.90, 0.20, 0.30)]),
        ]
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
                        if added > 0 { store.showToast(String(localized: "已放上暂存架：\(added) 个")) }
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
                ProBadge()
                    .opacity(license.isPro ? 0.55 : 1)
            }
            .tag(SidebarItem.folderWall)
            .help("固定的文件夹变成卡片墙")

            Section("资料库") {
                ForEach(FileCategory.allCases) { category in
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.symbol)
                            .foregroundStyle(category.tint)
                    }
                    .badge(store.totals[category].map { Text("\($0.count)") })
                    .tag(SidebarItem.category(category))
                }
            }

            Section("智能文件夹") {
                HStack {
                    Label("大文件", systemImage: "externaldrive")
                    Spacer()
                    if store.largeFileCount > 0 {
                        Text(store.largeFileCount > 999 ? "999+" : "\(store.largeFileCount)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .help("200 MB 以上的文件")
                    }
                }
                .tag(SidebarItem.largeFiles)
                Label("截图", systemImage: "camera.viewfinder")
                    .tag(SidebarItem.screenshots)
                Label("下载来源", systemImage: "arrow.down.circle")
                    .badge(store.sourceGroups.isEmpty ? nil : Text("\(store.sourceGroups.count)"))
                    .tag(SidebarItem.downloads)
            }

            SavedSearchesSidebarSection()

            Section("整理") {
                Label("清理", systemImage: "sparkles")
                    .badge(cleanup.totalBytes > 0 ? Text(cleanup.totalBytes.byteText).foregroundColor(.green) : nil)
                    .tag(SidebarItem.cleanup)
                Label("重复文件", systemImage: "doc.on.doc")
                    .badge(duplicates.hasScanned && duplicates.reclaimable > 0 ? Text(duplicates.reclaimable.byteText).foregroundColor(.green) : nil)
                    .tag(SidebarItem.duplicates)
                Label("相似照片", systemImage: "photo.stack")
                    .tag(SidebarItem.similarPhotos)
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
                Section("聊天文件") {
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

            Section("位置") {
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

            Section("标签") {
                ForEach(FinderTag.colorTags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                            .frame(width: 20)
                    }
                    .tag(SidebarItem.tag(tag.name))
                }
                ForEach(customTags.tags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle()
                            .fill(FinderTag.color(tag.color))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                            .frame(width: 20)
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
                    }
                }
                Button {
                    if let new = CustomTagStore.prompt() {
                        Task { await TagSync.addOrRecolor(new.name, color: new.color, store: store) }
                    }
                } label: {
                    Label("新建标签…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Section {
                // 和「位置」重复的固定（旧版本固定过桌面等）不再显示第二行。
                ForEach(store.pinnedFolders.filter { !LibraryStore.builtInLocationPaths.contains($0) }, id: \.self) { path in
                    Label {
                        Text((path as NSString).lastPathComponent)
                    } icon: {
                        BadgeIcon(symbol: "folder.fill", colors: [Self.rgb(0.55, 0.70, 0.95), Self.rgb(0.35, 0.50, 0.85)])
                    }
                        .help(path)
                        .tag(SidebarItem.pinned(path))
                        .simultaneousGesture(TapGesture().onEnded { store.reselect(.pinned(path)) })
                        .contextMenu {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            Button("取消固定") { store.unpin(path) }
                        }
                }
            } header: {
                HStack {
                    Text("固定文件夹")
                    Spacer()
                    Button {
                        store.choosePinnedFolder()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("固定一个文件夹")
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(SavedSearchRenameAlert())
    }
}
