import AppKit
import CoreText
import Foundation
import OSLog

/// 字体页的页内标签。
enum FontsTab: String, CaseIterable, Identifiable {
    case library, specimen, problems, stored, sets
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return String(localized: "字体库")
        case .specimen: return String(localized: "样张")
        case .problems: return String(localized: "问题字体")
        case .stored: return String(localized: "已停用")
        case .sets: return String(localized: "字体集")
        }
    }
}

/// 打开绑定了字体集的项目文件夹时，页面顶上的小横幅。
struct FontProjectBanner: Identifiable, Equatable {
    let id = UUID()
    let setID: UUID
    let text: String
    /// 「询问」模式：横幅上有「启用」按钮。
    let needsConfirm: Bool
}

/// 字体管理：扫描字体、停用 / 启用、问题字体、压缩存放和移动硬盘（Pro）、字体集和项目绑定（Pro）。
/// 所有读写磁盘的事都在后台做；系统字体（/System）永远不碰，/Library/Fonts 要管理员权限，只看不动。
@MainActor
final class FontLibrary: ObservableObject {
    static let shared = FontLibrary()

    @Published private(set) var faces: [FontFace] = []
    @Published private(set) var families: [FontFamily] = []
    @Published private(set) var issues: [FontIssueGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var manifest = FontManifest()
    /// 正在做的事（停用、压缩……），界面上显示转圈。
    @Published private(set) var busy: String?
    @Published var tab: FontsTab = .library
    /// 这次登录里临时启用（.session）的文件。
    @Published private(set) var sessionActive: Set<String> = []
    @Published var projectBanner: FontProjectBanner?

    /// 这次打开拾掇以后已经为哪些字体集问过 / 启用过（在项目里进进出出不反复提示）。
    private var handledSets: Set<UUID> = []
    private var scanTask: Task<Void, Never>?
    private var manifestLoaded = false

    private init() {}

    nonisolated static var home: String { NSHomeDirectory() }
    nonisolated static var manifestURL: URL {
        URL(fileURLWithPath: FontPathRules.storeRoot(home: home)).appendingPathComponent("manifest.json")
    }

    var archiveFolder: String { manifest.archiveFolder ?? FontPathRules.archiveFolder(home: Self.home) }

    var actionableIssueCount: Int { issues.reduce(0) { $0 + $1.actionableExtras.count } }
    var actionableIssueBytes: Int64 { issues.reduce(0) { $0 + $1.actionableBytes } }

    private var store: LibraryStore? { LibraryStore.shared }

    // MARK: 清单

    private func loadManifestIfNeeded() {
        guard !manifestLoaded else { return }
        manifestLoaded = true
        if let data = try? Data(contentsOf: Self.manifestURL) {
            if let decoded = FontManifest.decode(data) {
                manifest = decoded
            } else {
                // 读不出来：先备份一份，免得之后保存时把原来的覆盖掉。
                let backup = Self.manifestURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: Self.manifestURL, to: backup)
            }
        }
    }

    private func saveManifest() {
        let snapshot = manifest
        Task.detached(priority: .utility) {
            do {
                let url = FontLibrary.manifestURL
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FontManifest.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                AppLog.files.error("Font manifest save failed: \(AppLog.describe(error), privacy: .public)")
            }
        }
    }

    // MARK: 扫描

    func scanIfNeeded() {
        guard !hasScanned, !isScanning else { return }
        scan()
    }

    func scan() {
        loadManifestIfNeeded()
        scanTask?.cancel()
        FontPreviewCache.invalidate()
        isScanning = true
        let entries = manifest.entries
        let home = Self.home
        scanTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                FontScanner.scan(home: home, entries: entries)
            }.value
            guard !Task.isCancelled else { return }
            if !result.orphans.isEmpty {
                manifest.entries.append(contentsOf: result.orphans)
                saveManifest()
            }
            faces = result.faces
            families = FontLibraryLogic.families(result.faces)
            issues = FontIssueLogic.issues(files: result.files, damaged: result.damaged)
            isScanning = false
            hasScanned = true
        }
    }

    // MARK: 停用 / 启用（免费）

    /// 停用：把 ~/Library/Fonts 里的字体文件移进拾掇字体仓库，记下原来的位置。可撤销。
    func disable(paths: [String], registerUndo: Bool = true) async {
        loadManifestIfNeeded()
        let home = Self.home
        var unique: [String] = []
        for path in paths where !unique.contains(path) { unique.append(path) }
        let allowed = unique.filter { FontPathRules.canDisable($0, home: home) }
        let adminCount = unique.filter(FontPathRules.needsAdmin).count
        let systemCount = unique.filter(FontPathRules.isSystem).count
        guard !allowed.isEmpty else {
            explainSkipped(admin: adminCount, system: systemCount)
            return
        }
        // 临时启用过的先停掉。
        for path in allowed where sessionActive.contains(path) { unregisterSession(path) }
        let meta = metadata(for: allowed)
        busy = String(localized: "正在停用…")
        let outcome = await Task.detached(priority: .userInitiated) {
            FontFileOps.disable(allowed, meta: meta, home: home)
        }.value
        busy = nil
        manifest.entries.append(contentsOf: outcome.entries)
        saveManifest()
        scan()
        let done = outcome.entries.count
        if done > 0 {
            let originals = outcome.entries.map(\.originalPath)
            let text = String(localized: "已停用 \(done) 个字体文件（没有删除，随时可以启用）")
            if registerUndo {
                FileUndoCenter.shared.registerCustom(name: String(localized: "停用字体"), toast: text, undo: {
                    await FontLibrary.shared.enable(originalPaths: originals)
                }, redo: {
                    await FontLibrary.shared.disable(paths: originals, registerUndo: false)
                })
            } else {
                store?.showToast(text)
            }
        }
        var notes: [String] = []
        if !outcome.failed.isEmpty {
            notes.append(String(localized: "\(outcome.failed.count) 个没有停用（文件已经不在，或没有权限）：\(FileUndoLogic.names(outcome.failed.map { ($0 as NSString).lastPathComponent }))"))
        }
        if adminCount > 0 { notes.append(Self.adminNote(adminCount)) }
        if systemCount > 0 { notes.append(Self.systemNote) }
        if !notes.isEmpty { store?.alertMessage = notes.joined(separator: "\n") }
    }

    /// 按原来的路径启用（撤销停用时用）。
    func enable(originalPaths: [String]) async {
        let set = Set(originalPaths.map(FontPathRules.normalize))
        let ids = manifest.entries.filter { set.contains(FontPathRules.normalize($0.originalPath)) }.map(\.id)
        await enable(entryIDs: ids, registerUndo: false)
    }

    /// 启用：放回 ~/Library/Fonts（原来在那里就放回原处；同名的已经有了就换个名字，不覆盖），再注册。
    /// 压缩存放、移动硬盘上的也能直接启用：先取回再放回去（Pro 过期了也能取回自己的字体）。
    func enable(entryIDs: [UUID], registerUndo: Bool = true) async {
        loadManifestIfNeeded()
        let entries = manifest.entries.filter { entryIDs.contains($0.id) }
        guard !entries.isEmpty else { return }
        for entry in entries where sessionActive.contains(entry.storedPath) { unregisterSession(entry.storedPath) }
        let home = Self.home
        busy = String(localized: "正在启用…")
        let outcome = await Task.detached(priority: .userInitiated) {
            FontFileOps.enable(entries, home: home)
        }.value
        busy = nil
        manifest.entries.removeAll { outcome.done.contains($0.id) }
        saveManifest()
        scan()
        let done = outcome.done.count
        if done > 0 {
            let restored = outcome.restoredPaths
            let text = String(localized: "已启用 \(done) 个字体文件")
            if registerUndo {
                FileUndoCenter.shared.registerCustom(name: String(localized: "启用字体"), toast: text, undo: {
                    await FontLibrary.shared.disable(paths: restored, registerUndo: false)
                }, redo: {
                    await FontLibrary.shared.enable(originalPaths: restored)
                })
            } else {
                store?.showToast(text)
            }
        }
        if !outcome.failed.isEmpty {
            store?.alertMessage = String(localized: "\(outcome.failed.count) 个没有启用（找不到文件：移动硬盘没接上，或文件被移走了）：\(FileUndoLogic.names(outcome.failed))")
        }
    }

    /// 问题字体里的「移到废纸篓」：只收 ~/Library/Fonts 里的，走拾掇统一的废纸篓（记进清理记录、可撤销）。
    func trash(paths: [String]) {
        let home = Self.home
        let allowed = paths.filter { FontPathRules.canDisable($0, home: home) }
        let items = allowed.compactMap { FileItem(url: URL(fileURLWithPath: $0)) }
        guard let store, !items.isEmpty else {
            explainSkipped(admin: paths.filter(FontPathRules.needsAdmin).count, system: paths.filter(FontPathRules.isSystem).count)
            return
        }
        store.moveToTrash(items) { [weak self] _ in
            self?.scan()
        }
    }

    private func explainSkipped(admin: Int, system: Int) {
        var notes: [String] = []
        if admin > 0 { notes.append(Self.adminNote(admin)) }
        if system > 0 { notes.append(Self.systemNote) }
        if notes.isEmpty { notes.append(String(localized: "只有「用户字体」（~/Library/Fonts 里的）可以停用。")) }
        store?.alertMessage = notes.joined(separator: "\n")
    }

    static func adminNote(_ count: Int) -> String {
        String(localized: "\(count) 个在 /Library/Fonts 里（这台 Mac 所有用户共用），改动要管理员权限，拾掇不动它们。需要的话可以在访达里手动处理。")
    }

    static var systemNote: String {
        String(localized: "系统字体是 macOS 自带的，拾掇只显示、永远不动。")
    }

    /// 停用时记进清单的信息（家族、PostScript 名字……），从扫描结果里取。
    private func metadata(for paths: [String]) -> [String: FontFileOps.Meta] {
        var result: [String: FontFileOps.Meta] = [:]
        for path in paths {
            let list = faces.filter { $0.path == path }
            guard let first = list.first else { continue }
            result[path] = FontFileOps.Meta(family: first.family, localizedFamily: first.localizedFamily,
                                            postScriptNames: list.map(\.postScriptName), styles: list.map(\.style),
                                            version: first.version, coversCJK: list.contains(where: \.coversCJK))
        }
        return result
    }

    // MARK: 压缩存放 / 搬到移动硬盘（Pro）

    /// 压缩存放：停用中的字体逐个打成 zip（系统自带的 ditto），核对能解开、大小对得上后，原文件移到废纸篓。
    func archive(entryIDs: [UUID]) async {
        guard ShelfTools.requirePro() else { return }
        let entries = manifest.entries.filter { entryIDs.contains($0.id) && $0.storage == .disabled }
        guard !entries.isEmpty else { return }
        for entry in entries where sessionActive.contains(entry.storedPath) { unregisterSession(entry.storedPath) }
        let folder = archiveFolder
        busy = String(localized: "正在压缩…")
        let outcome = await Task.detached(priority: .userInitiated) {
            FontFileOps.archive(entries, folder: folder)
        }.value
        busy = nil
        apply(outcome.updated)
        if !outcome.updated.isEmpty {
            let saved = outcome.updated.reduce(Int64(0)) { $0 + max(0, $1.size - ($1.archivedSize ?? $1.size)) }
            store?.showToast(String(localized: "已压缩存放 \(outcome.updated.count) 个，省下 \(saved.byteText)（原文件在废纸篓里，清空后才真正腾出空间）"))
        }
        if !outcome.failed.isEmpty {
            store?.alertMessage = String(localized: "\(outcome.failed.count) 个没有压缩（原文件没动）：\(FileUndoLogic.names(outcome.failed))")
        }
    }

    /// 搬到移动硬盘 / 其他文件夹：放进「拾掇字体」文件夹，清单里记着，接上硬盘就能取回。
    func moveToExternal(entryIDs: [UUID], folder: URL) async {
        guard ShelfTools.requirePro() else { return }
        let entries = manifest.entries.filter { entryIDs.contains($0.id) && $0.storage == .disabled }
        guard !entries.isEmpty else { return }
        for entry in entries where sessionActive.contains(entry.storedPath) { unregisterSession(entry.storedPath) }
        let home = Self.home
        let destination = folder.path
        guard !FontPathRules.isSystem(destination), !FontPathRules.isInStore(destination, home: home),
              !FontPathRules.isInside(destination, folder: FontPathRules.userFonts(home: home)),
              FontPathRules.normalize(destination) != FontPathRules.normalize(FontPathRules.userFonts(home: home)) else {
            store?.alertMessage = String(localized: "不能搬到这个文件夹，请选移动硬盘或其他普通文件夹。")
            return
        }
        busy = String(localized: "正在搬…")
        let outcome = await Task.detached(priority: .userInitiated) {
            FontFileOps.moveExternal(entries, folder: destination)
        }.value
        busy = nil
        apply(outcome.updated)
        if !outcome.updated.isEmpty {
            store?.showToast(String(localized: "已搬走 \(outcome.updated.count) 个字体文件"))
        }
        if !outcome.failed.isEmpty {
            store?.alertMessage = String(localized: "\(outcome.failed.count) 个没有搬走（原文件没动）：\(FileUndoLogic.names(outcome.failed))")
        }
    }

    /// 取回：压缩存放的解压、移动硬盘上的搬回拾掇字体仓库（还是停用状态）。
    func retrieve(entryIDs: [UUID]) async {
        let entries = manifest.entries.filter { entryIDs.contains($0.id) && $0.storage != .disabled }
        guard !entries.isEmpty else { return }
        for entry in entries where sessionActive.contains(entry.storedPath) { unregisterSession(entry.storedPath) }
        let home = Self.home
        busy = String(localized: "正在取回…")
        let outcome = await Task.detached(priority: .userInitiated) {
            FontFileOps.retrieve(entries, home: home)
        }.value
        busy = nil
        apply(outcome.updated)
        if !outcome.updated.isEmpty {
            store?.showToast(String(localized: "已取回 \(outcome.updated.count) 个字体文件"))
        }
        if !outcome.failed.isEmpty {
            store?.alertMessage = String(localized: "\(outcome.failed.count) 个没有取回（移动硬盘没接上，或文件不在了）：\(FileUndoLogic.names(outcome.failed))")
        }
    }

    func setArchiveFolder(_ url: URL?) {
        guard ShelfTools.requirePro() else { return }
        manifest.archiveFolder = url?.path
        saveManifest()
    }

    private func apply(_ updated: [FontStoreEntry]) {
        guard !updated.isEmpty else { return }
        for entry in updated {
            if let index = manifest.entries.firstIndex(where: { $0.id == entry.id }) { manifest.entries[index] = entry }
        }
        saveManifest()
        scan()
    }

    // MARK: 字体集（Pro）

    @discardableResult
    func createSet(name: String, postScriptNames: [String] = []) -> FontSet? {
        guard ShelfTools.requirePro() else { return nil }
        loadManifestIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let set = FontSet(name: trimmed.isEmpty ? String(localized: "新字体集") : trimmed, postScriptNames: postScriptNames)
        manifest.sets.append(set)
        saveManifest()
        return set
    }

    func updateSet(_ set: FontSet) {
        guard let index = manifest.sets.firstIndex(where: { $0.id == set.id }) else { return }
        manifest.sets[index] = set
        saveManifest()
    }

    func deleteSet(_ id: UUID) {
        manifest.sets.removeAll { $0.id == id }
        saveManifest()
    }

    func add(_ family: FontFamily, to setID: UUID) {
        guard ShelfTools.requirePro(), var set = manifest.sets.first(where: { $0.id == setID }) else { return }
        for face in family.faces where !face.isDamaged && !set.postScriptNames.contains(face.postScriptName) {
            set.postScriptNames.append(face.postScriptName)
        }
        updateSet(set)
        store?.showToast(String(localized: "已把「\(family.displayName)」加入「\(set.name)」"))
    }

    /// 字体集里每个名字现在对应的字形。
    func members(of set: FontSet) -> [FontFace] {
        FontLibraryLogic.resolve(set.postScriptNames, in: faces)
    }

    /// 字体集里找不到的名字（文件删了 / 还没扫描）。
    func missingNames(of set: FontSet) -> [String] {
        let found = Set(members(of: set).map(\.postScriptName))
        return set.postScriptNames.filter { !found.contains($0) }
    }

    func isActive(_ set: FontSet) -> Bool {
        let list = members(of: set)
        guard !list.isEmpty else { return false }
        return list.allSatisfy { $0.location.isInstalled || sessionActive.contains($0.path) || sessionActive.contains(tempPath(for: $0)) }
    }

    /// 临时启用：停用中 / 移动硬盘上的直接注册到这次登录（.session，注销后自动失效）；压缩存放的先解压到临时文件夹。
    /// 返回这个字体集里现在能用的字形数。
    @discardableResult
    func activate(_ set: FontSet, quiet: Bool = false) async -> Int {
        guard ShelfTools.requirePro() else { return 0 }
        let list = members(of: set)
        var paths: [String] = []
        var archived: [FontStoreEntry] = []
        for face in list where !face.location.isInstalled {
            if face.location == .archived {
                if let id = face.manifestID, let entry = manifest.entries.first(where: { $0.id == id }),
                   !archived.contains(where: { $0.id == id }) {
                    archived.append(entry)
                }
            } else if !paths.contains(face.path) {
                paths.append(face.path)
            }
        }
        let home = Self.home
        let toRegister = paths
        let archivedList = archived
        let result = await Task.detached(priority: .userInitiated) { () -> (ok: [String], failed: [String]) in
            var ok: [String] = []
            var failed: [String] = []
            for path in toRegister {
                if FontFileOps.registerSession(path) { ok.append(path) } else { failed.append(path) }
            }
            for entry in archivedList {
                if let extracted = FontFileOps.extractToTemp(entry, home: home), FontFileOps.registerSession(extracted) {
                    ok.append(extracted)
                } else {
                    failed.append(entry.fileName)
                }
            }
            return (ok, failed)
        }.value
        sessionActive.formUnion(result.ok)
        let activeCount = list.filter { face in
            face.location.isInstalled || sessionActive.contains(face.path) || sessionActive.contains(tempPath(for: face))
        }.count
        if !quiet {
            store?.showToast(String(localized: "已临时启用「\(set.name)」：\(activeCount) 个字体（注销后自动停用）"))
        }
        if !result.failed.isEmpty {
            store?.alertMessage = String(localized: "\(result.failed.count) 个字体没能启用（移动硬盘没接上，或文件不在了）：\(FileUndoLogic.names(result.failed.map { ($0 as NSString).lastPathComponent }))")
        }
        return activeCount
    }

    /// 停止临时启用（只停这个字体集临时启用的；本来就装着的不动）。
    func deactivate(_ set: FontSet) {
        for face in members(of: set) {
            for path in [face.path, tempPath(for: face)] where sessionActive.contains(path) {
                unregisterSession(path)
            }
        }
        store?.showToast(String(localized: "已停止临时启用「\(set.name)」"))
    }

    private func unregisterSession(_ path: String) {
        CTFontManagerUnregisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .session, nil)
        sessionActive.remove(path)
    }

    private func tempPath(for face: FontFace) -> String {
        guard let id = face.manifestID, let entry = manifest.entries.first(where: { $0.id == id }) else { return "" }
        return FontFileOps.tempPath(for: entry, home: Self.home)
    }

    // MARK: 绑定项目（Pro）

    func bind(_ setID: UUID, folder: URL) {
        guard ShelfTools.requirePro(), var set = manifest.sets.first(where: { $0.id == setID }) else { return }
        let path = FontPathRules.normalize(folder.path)
        guard !set.boundFolders.contains(path) else { return }
        set.boundFolders.append(path)
        updateSet(set)
    }

    func unbind(_ setID: UUID, folder: String) {
        guard var set = manifest.sets.first(where: { $0.id == setID }) else { return }
        set.boundFolders.removeAll { $0 == folder }
        updateSet(set)
    }

    /// 在拾掇里打开了一个文件夹：它是某个字体集的项目文件夹时，按设置询问或自动启用。
    func folderOpened(_ folder: String) {
        guard LicenseManager.shared.isPro else { return }
        loadManifestIfNeeded()
        let mode = FontSetBinding.Mode(rawValue: UserDefaults.standard.string(forKey: FontSetBinding.modeKey) ?? "") ?? .ask
        guard mode != .off else { return }
        let matched = FontSetBinding.sets(for: folder, in: manifest.sets).filter { !handledSets.contains($0.id) }
        guard let set = matched.first else { return }
        handledSets.insert(set.id)
        Task {
            if !hasScanned {
                scan()
                await scanTask?.value
            }
            if isActive(set) { return }
            switch mode {
            case .auto:
                let count = await activate(set, quiet: true)
                if count > 0 { showBanner(FontProjectBanner(setID: set.id, text: String(localized: "已为此项目启用 \(count) 个字体"), needsConfirm: false)) }
            case .ask:
                showBanner(FontProjectBanner(setID: set.id, text: String(localized: "这个项目绑定了字体集「\(set.name)」"), needsConfirm: true))
            case .off:
                break
            }
        }
    }

    func confirmBanner() {
        guard let banner = projectBanner, let set = manifest.sets.first(where: { $0.id == banner.setID }) else { return }
        projectBanner = nil
        Task {
            let count = await activate(set, quiet: true)
            if count > 0 { showBanner(FontProjectBanner(setID: set.id, text: String(localized: "已为此项目启用 \(count) 个字体"), needsConfirm: false)) }
        }
    }

    private func showBanner(_ banner: FontProjectBanner) {
        projectBanner = banner
        let id = banner.id
        Task {
            try? await Task.sleep(nanoseconds: banner.needsConfirm ? 12_000_000_000 : 6_000_000_000)
            if projectBanner?.id == id { projectBanner = nil }
        }
    }
}

// MARK: - 后台：扫描

enum FontScanner {
    struct Result: Sendable {
        var faces: [FontFace] = []
        var files: [FontFileInfo] = []
        var damaged: [FontFileInfo] = []
        var orphans: [FontStoreEntry] = []
    }

    static func scan(home: String, entries: [FontStoreEntry]) -> Result {
        var result = Result()
        let disabled = FontPathRules.disabledFolder(home: home)
        let roots: [(String, FontLocation)] = [
            (FontPathRules.userFonts(home: home), .user),
            (FontPathRules.localFonts, .local),
            (FontPathRules.systemFonts, .system),
            (disabled, .disabled),
        ]
        let byStored = Dictionary(entries.map { (FontPathRules.normalize($0.storedPath), $0) }, uniquingKeysWith: { a, _ in a })
        var disabledFiles: [String] = []
        for (root, location) in roots {
            for url in fontFiles(in: root) {
                let entry = byStored[FontPathRules.normalize(url.path)]
                if location == .disabled { disabledFiles.append(url.path) }
                read(url, location: location, manifestID: entry?.id, into: &result)
            }
        }
        // 系统字体不全在 /System/Library/Fonts（苹方等是系统按需下载的资源，放在 /System/Library/AssetsV2 里）：
        // 问 Core Text 现在能用的字体，/System 下面还没读过的也算系统字体（只读，不碰）。
        var seen = Set(result.faces.map { FontPathRules.normalize($0.path) })
        for url in (CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? [] {
            let path = FontPathRules.normalize(url.path)
            guard FontPathRules.isSystem(path), FontFileFormat.extensions.contains(url.pathExtension.lowercased()),
                  seen.insert(path).inserted else { continue }
            read(url, location: .system, manifestID: nil, into: &result)
        }
        // 搬到移动硬盘的：硬盘接着就读文件；压缩存放的：按清单里记的信息显示。
        for entry in entries {
            switch entry.storage {
            case .disabled:
                continue
            case .external:
                if FileManager.default.fileExists(atPath: entry.storedPath) {
                    read(URL(fileURLWithPath: entry.storedPath), location: .external, manifestID: entry.id, into: &result)
                } else {
                    result.faces.append(contentsOf: placeholderFaces(entry, location: .external))
                }
            case .archived:
                result.faces.append(contentsOf: placeholderFaces(entry, location: .archived))
            }
        }
        result.orphans = FontManifest.orphanEntries(disabledFiles: disabledFiles, known: entries, home: home)
        return result
    }

    /// 文件夹里的字体文件（包括子文件夹；不跟进替身指向的文件夹）。
    static func fontFiles(in root: String) -> [URL] {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var list: [URL] = []
        for case let file as URL in enumerator where FontFileFormat.extensions.contains(file.pathExtension.lowercased()) {
            list.append(file)
        }
        return list
    }

    private static func placeholderFaces(_ entry: FontStoreEntry, location: FontLocation) -> [FontFace] {
        let names = entry.postScriptNames.isEmpty ? [(entry.fileName as NSString).deletingPathExtension] : entry.postScriptNames
        return names.enumerated().map { index, name in
            FontFace(postScriptName: name, family: entry.family, localizedFamily: entry.localizedFamily,
                     style: index < entry.styles.count ? entry.styles[index] : "", version: entry.version,
                     path: entry.storedPath, fileSize: entry.size,
                     format: FontFileFormat.from(extension: (entry.fileName as NSString).pathExtension),
                     isVariable: false, location: location, added: entry.date, modified: entry.date,
                     coversCJK: entry.coversCJK, manifestID: entry.id)
        }
    }

    private static func read(_ url: URL, location: FontLocation, manifestID: UUID?, into result: inout Result) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        let size = Int64(values?.fileSize ?? 0)
        let added = values?.addedToDirectoryDate ?? values?.creationDate
        let modified = values?.contentModificationDate
        let format = FontFileFormat.from(extension: url.pathExtension)
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        if descriptors.isEmpty {
            let stem = url.deletingPathExtension().lastPathComponent
            let info = FontFileInfo(path: url.path, location: location, size: size, modified: modified,
                                    postScriptNames: [], version: "", family: stem)
            result.damaged.append(info)
            result.faces.append(FontFace(postScriptName: stem, family: stem, localizedFamily: "", style: "", version: "",
                                         path: url.path, fileSize: size, format: format, isVariable: false,
                                         location: location, added: added, modified: modified, coversCJK: false,
                                         isDamaged: true, manifestID: manifestID))
            return
        }
        var names: [String] = []
        var version = ""
        var family = ""
        for descriptor in descriptors {
            let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
            let ps = CTFontCopyPostScriptName(font) as String
            let fam = CTFontCopyFamilyName(font) as String
            let localized = CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil).map { $0 as String } ?? fam
            let style = CTFontCopyName(font, kCTFontStyleNameKey).map { $0 as String } ?? ""
            let ver = CTFontCopyName(font, kCTFontVersionNameKey).map { $0 as String } ?? ""
            let axes = CTFontCopyVariationAxes(font) as? [Any]
            let face = FontFace(postScriptName: ps, family: fam, localizedFamily: localized, style: style, version: ver,
                                path: url.path, fileSize: size, format: format, isVariable: !(axes ?? []).isEmpty,
                                location: location, added: added, modified: modified,
                                coversCJK: FontCoverage.coversCJK(font: font), manifestID: manifestID)
            result.faces.append(face)
            names.append(ps)
            if version.isEmpty { version = ver }
            if family.isEmpty { family = localized.isEmpty ? fam : localized }
        }
        result.files.append(FontFileInfo(path: url.path, location: location, size: size, modified: modified,
                                         postScriptNames: names, version: version, family: family))
    }
}

// MARK: - 后台：文件操作（只移动，不覆盖；系统字体永远不碰）

enum FontFileOps {
    struct Meta: Sendable {
        var family: String
        var localizedFamily: String
        var postScriptNames: [String]
        var styles: [String]
        var version: String
        var coversCJK: Bool
    }

    struct DisableOutcome: Sendable {
        var entries: [FontStoreEntry] = []
        var failed: [String] = []
    }

    struct EnableOutcome: Sendable {
        var done: [UUID] = []
        var restoredPaths: [String] = []
        var failed: [String] = []
    }

    struct UpdateOutcome: Sendable {
        var updated: [FontStoreEntry] = []
        var failed: [String] = []
    }

    static func disable(_ paths: [String], meta: [String: Meta], home: String) -> DisableOutcome {
        var outcome = DisableOutcome()
        let fm = FileManager.default
        let folder = FontPathRules.disabledFolder(home: home)
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            outcome.failed = paths
            return outcome
        }
        for path in paths {
            // 再核对一次：只动 ~/Library/Fonts 里的字体文件。
            guard FontPathRules.canDisable(path, home: home), fm.fileExists(atPath: path) else {
                outcome.failed.append(path)
                continue
            }
            let url = URL(fileURLWithPath: path)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            CTFontManagerUnregisterFontsForURL(url as CFURL, .persistent, nil)
            let name = FontPathRules.uniqueName(url.lastPathComponent) { fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
            let destination = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name))
            do {
                try fm.moveItem(at: url, to: destination)
                let m = meta[path]
                outcome.entries.append(FontStoreEntry(originalPath: path, storedPath: destination.path, size: size,
                                                      family: m?.family ?? url.deletingPathExtension().lastPathComponent,
                                                      localizedFamily: m?.localizedFamily ?? "",
                                                      postScriptNames: m?.postScriptNames ?? [], styles: m?.styles ?? [],
                                                      version: m?.version ?? "", coversCJK: m?.coversCJK ?? false))
            } catch {
                // 没移成：重新注册回去，保持原样。
                CTFontManagerRegisterFontsForURL(url as CFURL, .persistent, nil)
                outcome.failed.append(path)
            }
        }
        return outcome
    }

    static func enable(_ entries: [FontStoreEntry], home: String) -> EnableOutcome {
        var outcome = EnableOutcome()
        let fm = FileManager.default
        let userFonts = FontPathRules.userFonts(home: home)
        try? fm.createDirectory(atPath: userFonts, withIntermediateDirectories: true)
        for entry in entries {
            var source: String?
            var tempDir: URL?
            switch entry.storage {
            case .disabled, .external:
                source = fm.fileExists(atPath: entry.storedPath) ? entry.storedPath : nil
            case .archived:
                let dir = fm.temporaryDirectory.appendingPathComponent("ShiduoFont-\(UUID().uuidString)", isDirectory: true)
                tempDir = dir
                source = unzip(entry.storedPath, into: dir, expecting: entry.fileName)
            }
            defer { if let tempDir { try? fm.removeItem(at: tempDir) } }
            guard let source else {
                outcome.failed.append(entry.fileName)
                continue
            }
            var target = FontPathRules.restoreTarget(originalPath: entry.originalPath, home: home)
            let parent = (target as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: target) {
                let name = FontPathRules.uniqueName((target as NSString).lastPathComponent) {
                    fm.fileExists(atPath: (parent as NSString).appendingPathComponent($0))
                }
                target = (parent as NSString).appendingPathComponent(name)
            }
            guard FontPathRules.canDisable(target, home: home) else {
                outcome.failed.append(entry.fileName)
                continue
            }
            do {
                try fm.moveItem(atPath: source, toPath: target)
            } catch {
                outcome.failed.append(entry.fileName)
                continue
            }
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: target) as CFURL, .persistent, nil)
            if entry.storage == .archived { try? fm.trashItem(at: URL(fileURLWithPath: entry.storedPath), resultingItemURL: nil) }
            outcome.done.append(entry.id)
            outcome.restoredPaths.append(target)
        }
        return outcome
    }

    static func archive(_ entries: [FontStoreEntry], folder: String) -> UpdateOutcome {
        var outcome = UpdateOutcome()
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil else {
            outcome.failed = entries.map(\.fileName)
            return outcome
        }
        for var entry in entries {
            guard fm.fileExists(atPath: entry.storedPath) else {
                outcome.failed.append(entry.fileName)
                continue
            }
            let name = FontPathRules.uniqueName(entry.fileName + ".zip") { fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
            let zip = (folder as NSString).appendingPathComponent(name)
            let original = Int64((try? URL(fileURLWithPath: entry.storedPath).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            guard run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", entry.storedPath, zip]) else {
                try? fm.removeItem(atPath: zip)
                outcome.failed.append(entry.fileName)
                continue
            }
            // 核对：解开看看，大小一样才算数。
            let check = fm.temporaryDirectory.appendingPathComponent("ShiduoFontCheck-\(UUID().uuidString)", isDirectory: true)
            let extracted = unzip(zip, into: check, expecting: (entry.storedPath as NSString).lastPathComponent)
            let extractedSize = extracted.flatMap { Int64((try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1) }
            try? fm.removeItem(at: check)
            guard extractedSize == original, original > 0 else {
                try? fm.removeItem(atPath: zip)
                outcome.failed.append(entry.fileName)
                continue
            }
            // 原文件移到废纸篓（不直接删）。
            guard (try? fm.trashItem(at: URL(fileURLWithPath: entry.storedPath), resultingItemURL: nil)) != nil else {
                try? fm.removeItem(atPath: zip)
                outcome.failed.append(entry.fileName)
                continue
            }
            entry.storage = .archived
            entry.storedPath = zip
            entry.archivedSize = Int64((try? URL(fileURLWithPath: zip).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if entry.size == 0 { entry.size = original }
            outcome.updated.append(entry)
        }
        return outcome
    }

    static func moveExternal(_ entries: [FontStoreEntry], folder: String) -> UpdateOutcome {
        var outcome = UpdateOutcome()
        let fm = FileManager.default
        let target = (folder as NSString).appendingPathComponent(String(localized: "拾掇字体"))
        guard (try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)) != nil else {
            outcome.failed = entries.map(\.fileName)
            return outcome
        }
        for var entry in entries {
            guard fm.fileExists(atPath: entry.storedPath) else {
                outcome.failed.append(entry.fileName)
                continue
            }
            let name = FontPathRules.uniqueName((entry.storedPath as NSString).lastPathComponent) {
                fm.fileExists(atPath: (target as NSString).appendingPathComponent($0))
            }
            let destination = (target as NSString).appendingPathComponent(name)
            do {
                try fm.moveItem(atPath: entry.storedPath, toPath: destination)
            } catch {
                outcome.failed.append(entry.fileName)
                continue
            }
            entry.storage = .external
            entry.storedPath = destination
            outcome.updated.append(entry)
        }
        return outcome
    }

    static func retrieve(_ entries: [FontStoreEntry], home: String) -> UpdateOutcome {
        var outcome = UpdateOutcome()
        let fm = FileManager.default
        let folder = FontPathRules.disabledFolder(home: home)
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for var entry in entries {
            let name = FontPathRules.uniqueName(entry.fileName) { fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0)) }
            let destination = (folder as NSString).appendingPathComponent(name)
            switch entry.storage {
            case .disabled:
                continue
            case .external:
                guard fm.fileExists(atPath: entry.storedPath), (try? fm.moveItem(atPath: entry.storedPath, toPath: destination)) != nil else {
                    outcome.failed.append(entry.fileName)
                    continue
                }
            case .archived:
                let dir = fm.temporaryDirectory.appendingPathComponent("ShiduoFont-\(UUID().uuidString)", isDirectory: true)
                defer { try? fm.removeItem(at: dir) }
                guard let file = unzip(entry.storedPath, into: dir, expecting: entry.fileName),
                      (try? fm.moveItem(atPath: file, toPath: destination)) != nil else {
                    outcome.failed.append(entry.fileName)
                    continue
                }
                try? fm.trashItem(at: URL(fileURLWithPath: entry.storedPath), resultingItemURL: nil)
                entry.archivedSize = nil
            }
            entry.storage = .disabled
            entry.storedPath = destination
            outcome.updated.append(entry)
        }
        return outcome
    }

    /// 临时启用压缩存放的字体：解压到拾掇字体仓库的 Temp 里（每条一个文件夹）。
    static func tempPath(for entry: FontStoreEntry, home: String) -> String {
        ((FontPathRules.tempFolder(home: home) as NSString).appendingPathComponent(entry.id.uuidString) as NSString)
            .appendingPathComponent(entry.fileName)
    }

    static func extractToTemp(_ entry: FontStoreEntry, home: String) -> String? {
        let path = tempPath(for: entry, home: home)
        if FileManager.default.fileExists(atPath: path) { return path }
        let dir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        guard let file = unzip(entry.storedPath, into: dir, expecting: entry.fileName) else { return nil }
        if file != path { try? FileManager.default.moveItem(atPath: file, toPath: path) }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 注册到这次登录（注销后自动失效）。已经注册过也算成功。
    static func registerSession(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .session, &error) { return true }
        guard let cfError = error?.takeRetainedValue() else { return false }
        return CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue
    }

    /// 用系统自带的 ditto 解压 zip；返回解出来的字体文件（优先名字对得上的）。
    static func unzip(_ zip: String, into dir: URL, expecting name: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: zip) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip, dir.path]) else { return nil }
        let files = FontScanner.fontFiles(in: dir.path)
        return (files.first { $0.lastPathComponent == name } ?? files.first)?.path
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - 预览用的字体

/// 样张 / 列表里预览字体：从文件直接读（停用的字体没注册也能预览）。
enum FontPreviewCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: [CTFontDescriptor]] = [:]

    static func font(for face: FontFace, size: CGFloat) -> NSFont? {
        guard !face.isDamaged, face.location != .archived else { return nil }
        lock.lock()
        var list = descriptors[face.path]
        lock.unlock()
        // 读过的直接用（列表每次重画、拖字号滑块都会走到这里，不再每次去磁盘上看文件在不在）。
        if list == nil {
            guard FileManager.default.fileExists(atPath: face.path) else { return nil }
            list = (CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: face.path) as CFURL) as? [CTFontDescriptor]) ?? []
            lock.lock()
            descriptors[face.path] = list
            lock.unlock()
        }
        guard let all = list, !all.isEmpty else { return nil }
        let match = all.first { descriptor in
            (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String) == face.postScriptName
        } ?? all[0]
        let font = CTFontCreateWithFontDescriptor(match, size, nil)
        return font as NSFont
    }

    static func invalidate() {
        lock.lock()
        descriptors.removeAll()
        lock.unlock()
    }
}
