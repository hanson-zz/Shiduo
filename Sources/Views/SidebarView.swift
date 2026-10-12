import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var cleanup: CleanupScanner
    @EnvironmentObject private var duplicates: DuplicateScanner
    @EnvironmentObject private var chat: ChatFilesStore

    /// 常用位置，和访达侧边栏一样。
    private struct Location: Identifiable {
        let name: String
        let symbol: String
        let path: String
        var id: String { path }
    }

    private var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Location(name: "桌面", symbol: "menubar.dock.rectangle", path: home + "/Desktop"),
            Location(name: "文稿", symbol: "doc", path: home + "/Documents"),
            Location(name: "下载", symbol: "arrow.down.circle", path: home + "/Downloads"),
            Location(name: "图片", symbol: "photo", path: home + "/Pictures"),
            Location(name: "影片", symbol: "film", path: home + "/Movies"),
            Location(name: "音乐", symbol: "music.note", path: home + "/Music"),
        ]
    }

    var body: some View {
        List(selection: $store.selection) {
            Label("首页", systemImage: "house")
                .tag(SidebarItem.home)

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

            Section("整理") {
                Label("清理", systemImage: "sparkles")
                    .badge(cleanup.totalBytes > 0 ? Text(cleanup.totalBytes.byteText).foregroundColor(.green) : nil)
                    .tag(SidebarItem.cleanup)
                Label("重复文件", systemImage: "doc.on.doc")
                    .badge(duplicates.hasScanned && duplicates.reclaimable > 0 ? Text(duplicates.reclaimable.byteText).foregroundColor(.green) : nil)
                    .tag(SidebarItem.duplicates)
                Label("相似照片", systemImage: "photo.stack")
                    .tag(SidebarItem.similarPhotos)
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
                        Image(nsImage: NSWorkspace.shared.icon(forFile: location.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    .help(location.path)
                    .tag(SidebarItem.pinned(location.path))
                }
            }

            Section {
                ForEach(store.pinnedFolders, id: \.self) { path in
                    Label {
                        Text((path as NSString).lastPathComponent)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                        .help(path)
                        .tag(SidebarItem.pinned(path))
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
    }
}
