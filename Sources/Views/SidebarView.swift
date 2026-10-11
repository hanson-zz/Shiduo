import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        List(selection: $store.selection) {
            Label("首页", systemImage: "house")
                .tag(SidebarItem.home)

            Section("资料库") {
                ForEach(FileCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbol)
                        .tag(SidebarItem.category(category))
                }
            }

            Section("智能文件夹") {
                Label("大文件", systemImage: "externaldrive")
                    .tag(SidebarItem.largeFiles)
                Label("截图", systemImage: "camera.viewfinder")
                    .tag(SidebarItem.screenshots)
                Label("下载来源", systemImage: "globe")
                    .tag(SidebarItem.downloads)
            }

            Section("整理") {
                Label("清理建议", systemImage: "sparkles")
                    .tag(SidebarItem.cleanup)
                Label("重复文件", systemImage: "doc.on.doc")
                    .tag(SidebarItem.duplicates)
                Label("相似照片", systemImage: "photo.stack")
                    .tag(SidebarItem.similarPhotos)
            }

            Section {
                ForEach(store.pinnedFolders, id: \.self) { path in
                    Label((path as NSString).lastPathComponent, systemImage: "folder")
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
