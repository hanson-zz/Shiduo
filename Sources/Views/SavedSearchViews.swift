import SwiftUI

/// 保存的搜索（Pro）打开后的页面：顶部是这句搜索理解成的条件，下面是文件列表。
struct SavedSearchPage: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var saved = SavedSearchStore.shared
    let id: UUID

    var body: some View {
        if let search = saved.search(id) {
            VStack(spacing: 0) {
                SavedSearchBar(search: search)
                Divider()
                BrowserView(title: search.displayName, showsOCRTools: false)
            }
        } else {
            ContentUnavailableView("这个保存的搜索已被删除", systemImage: "folder.badge.questionmark")
        }
    }
}

/// 保存的搜索页顶部：条件（只读）、编辑、重命名。
private struct SavedSearchBar: View {
    @EnvironmentObject private var store: LibraryStore
    let search: SavedSearch
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(search.query().chips) { chip in
                        Label(chip.label, systemImage: chip.symbol)
                            .font(.callout)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
            .help(String(localized: "搜索：\(search.text)"))
            Spacer(minLength: 8)
            Text("随时自动更新")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                store.editSavedSearch(search)
            } label: {
                Label("编辑搜索", systemImage: "pencil")
            }
            .help("把这句搜索放回搜索框，改好后可以另存一个")
            Button {
                newName = search.displayName
                renaming = true
            } label: {
                Label("重命名", systemImage: "character.cursor.ibeam")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .alert("重命名保存的搜索", isPresented: $renaming) {
            TextField("名称", text: $newName)
            Button("好") { SavedSearchStore.shared.rename(search.id, to: newName) }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 搜索结果顶部的「保存搜索」按钮：起个名字，存到侧边栏。
struct SaveSearchButton: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        if store.canSaveSearch {
            Button {
                name = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                naming = true
            } label: {
                HStack(spacing: 4) {
                    Label("保存搜索", systemImage: "plus.rectangle.on.folder")
                    if !license.isPro { ProBadge() }
                }
            }
            .buttonStyle(.borderless)
            .help("存到侧边栏，像文件夹一样随时打开，内容自动更新")
            .alert("保存到侧边栏", isPresented: $naming) {
                TextField("名称", text: $name)
                Button("保存") { store.saveCurrentSearch(name: name) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("「上周」「今天」这样的日期每次打开都按当时重新计算。")
            }
        }
    }
}

/// 侧边栏「保存的搜索」：可拖动排序，右键重命名 / 删除。
struct SavedSearchesSidebarSection: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var license: LicenseManager
    @ObservedObject private var saved = SavedSearchStore.shared

    var body: some View {
        if !saved.searches.isEmpty {
            Section {
                ForEach(saved.searches) { search in
                    HStack {
                        Label(search.displayName, systemImage: "folder.badge.gearshape")
                            .lineLimit(1)
                        Spacer()
                        if !license.isPro {
                            ProBadge().opacity(0.8)
                        } else if let count = saved.counts[search.id] {
                            Text(count >= 3000 ? "3000+" : "\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .help(search.text)
                    .tag(SidebarItem.savedSearch(search.id))
                    .contextMenu {
                        Button("重命名…") { saved.renamingID = search.id }
                        Button("编辑搜索") {
                            store.editSavedSearch(search)
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            if store.selection == .savedSearch(search.id) { store.selection = .home }
                            saved.delete(search.id)
                        }
                    }
                }
                .onMove { saved.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("保存的搜索")
            }
        }
    }
}

/// 侧边栏右键「重命名…」的输入框（挂在整个侧边栏上，不挂在 Section 上）。
struct SavedSearchRenameAlert: ViewModifier {
    @ObservedObject private var saved = SavedSearchStore.shared
    @State private var newName = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: saved.renamingID) {
                if let id = saved.renamingID { newName = saved.search(id)?.displayName ?? "" }
            }
            .alert("重命名保存的搜索", isPresented: Binding(
                get: { saved.renamingID != nil },
                set: { if !$0 { saved.renamingID = nil } }
            )) {
                TextField("名称", text: $newName)
                Button("好") {
                    if let id = saved.renamingID { saved.rename(id, to: newName) }
                    saved.renamingID = nil
                }
                Button("取消", role: .cancel) { saved.renamingID = nil }
            }
    }
}
