import SwiftUI

/// 重复文件页：顶部大横幅（可腾出多少 + 全部移到废纸篓），“完全相同 / 相似照片”两个标签，
/// 每组一张卡片，大缩略图上标着“保留 / 废纸篓”，点一下就换。
/// 完全相同：默认一份都不勾，第一份标「建议保留」（最近打开过的那份），用户自己点要移走的副本，或者点「按建议勾选」。
struct DuplicatesView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var exact: DuplicateScanner
    @EnvironmentObject private var similar: SimilarPhotoScanner

    /// 相似照片：每组保留哪些文件（没记录时保留最新的一份）。
    @State private var keep: [String: Set<String>] = [:]
    /// 完全相同：每组用户勾了要移到废纸篓的副本（默认都不勾）。
    @State private var marked: [String: Set<String>] = [:]
    @State private var confirmAll = false

    private var tab: DuplicatesTab { store.duplicatesTab }
    private var groups: [FileGroup] { tab == .exact ? exact.groups : similar.groups }
    private var isRunning: Bool { tab == .exact ? exact.isRunning : similar.isRunning }
    private var hasScanned: Bool { tab == .exact ? exact.hasScanned : similar.hasScanned }
    private var progress: Double { tab == .exact ? exact.progress : similar.progress }
    private var status: String { tab == .exact ? exact.status : similar.status }

    private func kept(_ group: FileGroup) -> Set<String> {
        if tab == .exact {
            let m = marked[group.id] ?? []
            return Set(group.items.map(\.id).filter { !m.contains($0) })
        }
        if let set = keep[group.id], !set.isEmpty, group.items.contains(where: { set.contains($0.id) }) {
            return set
        }
        return Set(group.items.first.map { [$0.id] } ?? [])
    }

    private func extras(_ group: FileGroup) -> [FileItem] {
        let k = kept(group)
        return group.items.filter { !k.contains($0.id) }
    }

    private var allExtras: [FileItem] { groups.flatMap(extras) }
    private var freeBytes: Int64 { allExtras.reduce(0) { $0 + $1.size } }
    /// 完全相同：每组只留建议的一份时能腾出多少（横幅上显示）。
    private var suggestedBytes: Int64 { exact.reclaimable }
    private var suggestedCount: Int { exact.groups.reduce(0) { $0 + max($1.items.count - 1, 0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("重复文件")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("完全相同的副本，以及连拍、编辑版、HEIC/JPEG 成对这类看起来差不多的照片")
                        .foregroundStyle(.secondary)
                }
                banner
                tabs
                if tab == .exact ? exact.mayBeStale : similar.mayBeStale {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                        Text("刚才撤销了移到废纸篓，放回的文件不会自动回到结果里。重新扫描一下更准确。")
                        Spacer()
                        Button("重新扫描") { rescan() }
                            .disabled(isRunning)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .glassCard(radius: 14)
                }
                content
                Label("不会直接删除，都进废纸篓，随时可以放回原处。只在 iCloud 云端的文件会被跳过。", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(tab == .exact ? String(localized: "重复文件") : String(localized: "相似照片"))
        .task(id: tab) { startIfNeeded() }
        .confirmationDialog(
            "将 \(allExtras.count) 个多余的副本移到废纸篓？",
            isPresented: $confirmAll,
            titleVisibility: .visible
        ) {
            Button("全部移到废纸篓", role: .destructive) {
                safeTrash(groups)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每组标着“保留”的文件不会动。随时可以从废纸篓里恢复。")
        }
    }

    private func startIfNeeded() {
        if Demo.isOn { return }
        if tab == .exact, !exact.hasScanned, !exact.isRunning { exact.start() }
        if tab == .similar, !similar.hasScanned, !similar.isRunning { similar.start() }
    }

    private func rescan() {
        keep = [:]
        marked = [:]
        if tab == .exact { exact.start() } else { similar.start() }
    }

    // MARK: - 横幅

    private var banner: some View {
        HStack(spacing: 22) {
            Image(systemName: tab == .exact ? "doc.on.doc" : "photo.stack")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 6) {
                if isRunning {
                    Text("正在扫描…")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    ProgressView(value: progress)
                        .tint(.white)
                        .frame(maxWidth: 280)
                    Text(status)
                        .foregroundStyle(.white.opacity(0.7))
                } else if hasScanned && tab == .exact {
                    Text("可腾出 \(suggestedBytes.byteText)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(groups.isEmpty
                         ? String(localized: "没有发现多余的副本，很整齐")
                         : (allExtras.isEmpty
                            ? String(localized: "\(suggestedCount) 个多余的副本，共 \(groups.count) 组 · 默认不勾，点副本勾选")
                            : String(localized: "已勾选 \(allExtras.count) 个副本 · \(freeBytes.byteText)")))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("完全相同 · SHA-256 指纹校验")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white))
                } else if hasScanned {
                    Text("可腾出 \(freeBytes.byteText)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(groups.isEmpty ? String(localized: "没有发现多余的副本，很整齐") : String(localized: "\(allExtras.count) 个多余的副本，共 \(groups.count) 组"))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(tab == .exact ? String(localized: "完全相同 · SHA-256 指纹校验") : String(localized: "画面相似 · Vision 本机比对"))
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white))
                } else {
                    Text("还没有扫描")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(tab == .exact ? String(localized: "按大小和 SHA-256 指纹比对，只有内容完全相同才算重复") : String(localized: "用 Vision 比较最近 800 张照片的画面"))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                if tab == .exact && hasScanned && !isRunning && !groups.isEmpty {
                    Button {
                        markSuggested()
                    } label: {
                        Label("按建议勾选", systemImage: "checkmark.circle")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .help("每组只留最近打开的一份，其余都勾上（还没移走，可以再改）")
                }
                Button {
                    // 少量的直接移（小提示上可以撤销）；大批量（≥100 个或 ≥5 GB）先确认。
                    if TrashConfirm.needsConfirm(count: allExtras.count, bytes: freeBytes) {
                        confirmAll = true
                    } else {
                        safeTrash(groups)
                    }
                } label: {
                    Label(tab == .exact ? String(localized: "移走勾选的副本") : String(localized: "全部移到废纸篓"), systemImage: "trash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(allExtras.isEmpty || isRunning)
                .opacity(allExtras.isEmpty || isRunning ? 0.5 : 1)

                Button {
                    if isRunning {
                        if tab == .exact { exact.cancel() } else { similar.cancel() }
                    } else {
                        rescan()
                    }
                } label: {
                    Label(isRunning ? String(localized: "停止") : (hasScanned ? String(localized: "重新扫描") : String(localized: "开始扫描")),
                          systemImage: isRunning ? "stop.fill" : "arrow.clockwise")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(26)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    // MARK: - 标签页

    private var tabs: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                tabButton(.exact, title: String(localized: "完全相同"), count: exact.groups.count)
                tabButton(.similar, title: String(localized: "相似照片"), count: similar.groups.count)
            }
            .padding(4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            if tab == .similar {
                HStack(spacing: 6) {
                    Text("严格").font(.caption)
                    Slider(value: Binding(get: { similar.threshold }, set: { similar.threshold = $0 }), in: 0.2...0.8)
                        .frame(width: 120)
                    Text("宽松").font(.caption)
                }
                .foregroundStyle(.secondary)
                .disabled(similar.isRunning)
                .help("调整后点“重新扫描”生效")
            }
        }
    }

    private func tabButton(_ value: DuplicatesTab, title: String, count: Int) -> some View {
        let selected = tab == value
        return Button {
            store.duplicatesTab = value
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .opacity(0.8)
                }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color.primary : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: isRunning ? "hourglass" : (hasScanned ? "checkmark.seal" : "magnifyingglass"))
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(isRunning ? String(localized: "正在比对，稍等一下…") : (hasScanned ? String(localized: "没有发现重复") : String(localized: "点“开始扫描”在本机查找")))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .glassCard()
        } else {
            LazyVStack(spacing: 16) {
                ForEach(groups) { group in
                    DuplicateGroupCard(
                        group: group,
                        kept: kept(group),
                        isSimilar: tab == .similar,
                        suggested: tab == .exact ? group.items.first?.id : nil,
                        toggle: { toggle($0, in: group) },
                        trashExtras: { trashExtras(group) }
                    )
                }
            }
        }
    }

    /// 完全相同：每组只留第一份（建议保留），其余都勾上。
    private func markSuggested() {
        var next: [String: Set<String>] = [:]
        for group in exact.groups {
            next[group.id] = Set(group.items.dropFirst().map(\.id))
        }
        marked = next
    }

    private func toggle(_ item: FileItem, in group: FileGroup) {
        if tab == .exact {
            // 完全相同：点一下勾上 / 取消要移走的副本；每组至少留一份。
            var m = marked[group.id] ?? []
            if m.contains(item.id) {
                m.remove(item.id)
            } else {
                guard group.items.filter({ !m.contains($0.id) }).count > 1 else {
                    store.showToast(String(localized: "每组至少保留一份"))
                    return
                }
                m.insert(item.id)
            }
            marked[group.id] = m
            return
        }
        var set = kept(group)
        if set.contains(item.id) {
            guard set.count > 1 else {
                store.showToast(String(localized: "每组至少保留一张"))
                return
            }
            set.remove(item.id)
        } else {
            set.insert(item.id)
        }
        keep[group.id] = set
    }

    private func trashExtras(_ group: FileGroup) {
        guard !extras(group).isEmpty else { return }
        safeTrash([group])
    }

    private func safeTrash(_ list: [FileGroup]) {
        let plans = list.map { group -> (kept: [FileItem], extras: [FileItem]) in
            let k = kept(group)
            return (group.items.filter { k.contains($0.id) }, group.items.filter { !k.contains($0.id) })
        }
        store.trashDuplicateExtras(plans, exact: tab == .exact)
    }
}

extension LibraryStore {
    /// 把重复文件每组多余的副本移到废纸篓。移之前先核对每组「保留」的那份还在、没被改过（扫描之后可能在访达里动过）；
    /// 对不上的组跳过，免得把这个文件的所有副本都删掉。重复文件页和清理页「放心清」共用。
    func trashDuplicateExtras(_ list: [(kept: [FileItem], extras: [FileItem])], exact: Bool) {
        let plans = list.filter { !$0.extras.isEmpty && !$0.kept.isEmpty }.map { plan -> (extras: [FileItem], check: DuplicateSafety.Group) in
            let check = DuplicateSafety.Group(
                kept: plan.kept.map { .init(path: $0.path, size: $0.size) },
                extras: plan.extras.map { .init(path: $0.path, size: $0.size) },
                exact: exact
            )
            return (plan.extras, check)
        }
        guard !plans.isEmpty else { return }
        let checks = plans.map(\.check)
        Task {
            let safe = await Task.detached(priority: .userInitiated) {
                checks.map { DuplicateSafety.isSafe($0) }
            }.value
            let toTrash = zip(plans, safe).filter { $0.1 }.flatMap { $0.0.extras }
            let changed = safe.filter { !$0 }.count
            if !toTrash.isEmpty { moveToTrash(toTrash) }
            if changed > 0 {
                alertMessage = String(localized: "\(changed) 组在扫描之后有变化（保留的文件被移走、删除或改过），这几组没有动。请重新扫描。")
            }
        }
    }
}

struct DuplicateGroupCard: View {
    let group: FileGroup
    let kept: Set<String>
    let isSimilar: Bool
    /// 完全相同：建议保留的那份（最近打开过的）。
    var suggested: String? = nil
    let toggle: (FileItem) -> Void
    let trashExtras: () -> Void

    private var extraItems: [FileItem] { group.items.filter { !kept.contains($0.id) } }
    private var freeBytes: Int64 { extraItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSimilar ? group.title : (group.items.first?.name ?? ""))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(isSimilar
                         ? String(localized: "\(group.items.count) 张 · 可腾出 \(freeBytes.byteText)")
                         : (extraItems.isEmpty
                            ? String(localized: "\(group.items.count) 份完全相同 · 每份 \(group.items.first?.sizeText ?? "") · 点副本勾选要移走的")
                            : String(localized: "\(group.items.count) 份完全相同 · 可腾出 \(freeBytes.byteText)")))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: trashExtras) {
                    Label("保留 \(kept.count) 个，删 \(extraItems.count) 个", systemImage: "trash")
                        .glassCapsule()
                }
                .buttonStyle(.plain)
                .disabled(extraItems.isEmpty)
                .help("把标着“废纸篓”的文件移到废纸篓")
                .opacity(extraItems.isEmpty ? 0.5 : 1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(group.items) { item in
                        DuplicateItemCard(item: item, isKept: kept.contains(item.id), showsName: isSimilar,
                                          isSuggested: item.id == suggested, plainKeep: !isSimilar && item.id != suggested)
                            .onTapGesture { toggle(item) }
                            .stableContextMenu { FileContextMenu(items: [item]) }
                            .onDrag { InAppDrag.copyOnlyProvider(item.url) }
                            .help("点一下切换“保留 / 废纸篓”\n\(item.path)")
                    }
                }
                .padding(2)
            }
        }
        .padding(18)
        .glassCard()
    }
}

struct DuplicateItemCard: View {
    let item: FileItem
    let isKept: Bool
    var showsName = false
    /// 建议保留的那份（标「建议保留」）。
    var isSuggested = false
    /// 没勾、也不是建议保留的副本：标灰色「保留」、不加绿框（完全相同默认都不勾）。
    var plainKeep = false

    private let keepColor = Color(red: 0.13, green: 0.68, blue: 0.42)
    private let trashColor = Color(red: 0.92, green: 0.28, blue: 0.28)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(url: item.url, size: 180, fill: true, modified: item.modified, isFolder: item.isPlainFolder)
                    .frame(width: 180, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(isKept ? 1 : 0.75)
                Text(!isKept ? String(localized: "废纸篓") : (isSuggested ? String(localized: "建议保留") : String(localized: "保留")))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(!isKept ? trashColor : (plainKeep ? Color.gray : keepColor)))
                    .padding(8)
            }
            if showsName {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 180, alignment: .leading)
            }
            Text(item.displayFolder)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            Text("\(item.sizeText) · \(item.relativeDateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isKept && !plainKeep ? keepColor.opacity(0.08) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(!isKept ? ((isSuggested || plainKeep) ? trashColor.opacity(0.7) : Color.clear) : (plainKeep ? Color.clear : keepColor), lineWidth: 2)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isKept)
    }
}
