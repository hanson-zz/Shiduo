import CoreText
import Foundation

// MARK: - 字体管理里不依赖界面、能单元测试的部分
// 字体在哪、能不能动、重复 / 多版本怎么分组、停用清单怎么存、字体集绑定哪个文件夹、是不是中文字体。

/// 字体文件在哪儿。
enum FontLocation: String, Codable, Sendable, CaseIterable {
    /// ~/Library/Fonts：只有这里的字体拾掇能停用 / 启用。
    case user
    /// /Library/Fonts：所有用户共用，要管理员权限，拾掇只看不动。
    case local
    /// /System/Library/Fonts：系统字体，只显示，永远不碰。
    case system
    /// 拾掇停用的（~/Library/Application Support/Shiduo/Fonts/Disabled）。
    case disabled
    /// 停用后搬到移动硬盘 / 其他文件夹的（Pro）。
    case external
    /// 停用后压缩存放的（Pro）。
    case archived

    /// 现在系统里能用（装着、启用着）。
    var isInstalled: Bool { self == .user || self == .local || self == .system }
    /// 拾掇停用的（不管放在哪儿）。
    var isStoredByShiduo: Bool { self == .disabled || self == .external || self == .archived }
}

/// 字体文件格式（按扩展名；可变字体另外标）。
enum FontFileFormat: String, Codable, Sendable, CaseIterable {
    case ttf, otf, ttc, otc, dfont, other

    static func from(extension ext: String) -> FontFileFormat {
        switch ext.lowercased() {
        case "ttf": return .ttf
        case "otf": return .otf
        case "ttc": return .ttc
        case "otc": return .otc
        case "dfont": return .dfont
        default: return .other
        }
    }

    /// 字体管理认的扩展名（其他文件不扫）。
    static let extensions: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]

    var label: String {
        self == .other ? "?" : rawValue.uppercased()
    }
}

/// 一个字形（一个 PostScript 名字）。TTC / OTC 一个文件里有好几个。
struct FontFace: Identifiable, Hashable, Sendable {
    var postScriptName: String
    /// 家族名（英文 / 原始名字，用来分组）。
    var family: String
    /// 本地化的家族名（中文系统下中文字体显示中文名，比如「苹方-简」）。
    var localizedFamily: String
    var style: String
    var version: String
    var path: String
    /// 整个文件的大小（TTC 里几个字形共用一个文件）。
    var fileSize: Int64
    var format: FontFileFormat
    var isVariable: Bool
    var location: FontLocation
    var added: Date?
    var modified: Date?
    var coversCJK: Bool
    /// 系统读不出来（损坏 / 不完整）。
    var isDamaged: Bool = false
    /// 拾掇停用清单里的哪一条（停用 / 压缩 / 移动硬盘的才有）。
    var manifestID: UUID?

    var id: String { path + "#" + postScriptName }
    var fileName: String { (path as NSString).lastPathComponent }
    /// 显示用的家族名。
    var displayFamily: String { localizedFamily.isEmpty ? family : localizedFamily }
}

/// 一个字体家族：同一个家族名的所有字形。
struct FontFamily: Identifiable, Hashable, Sendable {
    var name: String
    var displayName: String
    var faces: [FontFace]

    var id: String { name }
    var styleCount: Int { faces.count }
    /// 家族里不同文件的总大小（TTC 只算一次）。
    var totalBytes: Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for face in faces where seen.insert(face.path).inserted { total += face.fileSize }
        return total
    }
    /// 最大的一个文件。
    var largestFileBytes: Int64 { faces.map(\.fileSize).max() ?? 0 }
    var paths: [String] {
        var seen = Set<String>()
        return faces.map(\.path).filter { seen.insert($0).inserted }
    }
    var formats: [FontFileFormat] {
        let set = Set(faces.map(\.format))
        return FontFileFormat.allCases.filter(set.contains)
    }
    var isVariable: Bool { faces.contains(where: \.isVariable) }
    var locations: [FontLocation] {
        let set = Set(faces.map(\.location))
        return FontLocation.allCases.filter(set.contains)
    }
    var coversCJK: Bool { faces.contains(where: \.coversCJK) }
    var newestAdded: Date? { faces.compactMap { $0.added ?? $0.modified }.max() }
    /// 样张用的那一个字形：常规体优先，其次第一个。
    var representative: FontFace? {
        let regularNames = ["regular", "常规体", "常规", "標準體", "roman", "book", "normal", "w3", "medium"]
        return faces.first { face in regularNames.contains(face.style.lowercased()) && !face.isDamaged }
            ?? faces.first { !$0.isDamaged }
            ?? faces.first
    }
}

/// 字体库的排序。
enum FontSortKey: String, CaseIterable, Identifiable, Sendable {
    case name, size, total, added
    var id: String { rawValue }
}

/// 字体库的筛选。
enum FontFilter: String, CaseIterable, Identifiable, Sendable {
    case all, cjk, user, local, system, stored
    var id: String { rawValue }
}

// MARK: - 路径规则（安全）

enum FontPathRules {
    static let localFonts = "/Library/Fonts"
    static let systemFonts = "/System/Library/Fonts"

    static func userFonts(home: String) -> String { (home as NSString).appendingPathComponent("Library/Fonts") }
    /// 拾掇自己的字体仓库。
    static func storeRoot(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Application Support/Shiduo/Fonts")
    }
    static func disabledFolder(home: String) -> String { (storeRoot(home: home) as NSString).appendingPathComponent("Disabled") }
    static func archiveFolder(home: String) -> String { (storeRoot(home: home) as NSString).appendingPathComponent("Archive") }
    /// 临时启用压缩存放的字体时解压到这里。
    static func tempFolder(home: String) -> String { (storeRoot(home: home) as NSString).appendingPathComponent("Temp") }

    /// 规范化：去掉 .. 和多余的斜杠（不跟随替身）。
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// path 在 folder 里面（不含 folder 本身）。
    static func isInside(_ path: String, folder: String) -> Bool {
        let p = normalize(path)
        let f = normalize(folder)
        guard !f.isEmpty, p != f else { return false }
        return p.hasPrefix(f == "/" ? "/" : f + "/")
    }

    /// 路径里有没有 .. 这种会跳出去的部分（规范化前检查，防止拼出来的路径绕过前缀判断）。
    static func hasTraversal(_ path: String) -> Bool {
        path.split(separator: "/").contains("..")
    }

    static func isSystem(_ path: String) -> Bool {
        let p = normalize(path)
        return p == "/System" || p.hasPrefix("/System/")
    }

    /// 在 /Library/Fonts 里：要管理员权限，拾掇不动。
    static func needsAdmin(_ path: String) -> Bool { isInside(path, folder: localFonts) }

    /// 只有 ~/Library/Fonts 里的字体能停用（系统字体、/Library/Fonts 一律不碰）。
    static func canDisable(_ path: String, home: String) -> Bool {
        guard !hasTraversal(path), !isSystem(path), !needsAdmin(path) else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        guard FontFileFormat.extensions.contains(ext) else { return false }
        return isInside(path, folder: userFonts(home: home))
    }

    /// 拾掇仓库里的文件（停用的、临时解压的）。
    static func isInStore(_ path: String, home: String) -> Bool {
        !hasTraversal(path) && isInside(path, folder: storeRoot(home: home))
    }

    /// 启用时放回哪里：原来在 ~/Library/Fonts 里就放回原处，否则放到 ~/Library/Fonts 第一层。
    static func restoreTarget(originalPath: String, home: String) -> String {
        if canDisable(originalPath, home: home) { return normalize(originalPath) }
        let name = (originalPath as NSString).lastPathComponent
        return (userFonts(home: home) as NSString).appendingPathComponent(name.isEmpty ? "Font.ttf" : name)
    }

    /// 名字被占用时加「 2」「 3」…（扩展名保留）。
    static func uniqueName(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}

// MARK: - 版本号

enum FontVersion {
    /// 「Version 1.002;PS 1.2;hotconv」→ 1.002；读不出数字返回 nil。字体版本是定点小数（1.1 比 1.002 新）。
    static func parse(_ text: String) -> Decimal? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i].isASCII, chars[i].isNumber {
                var j = i
                var sawDot = false
                while j < chars.count {
                    let c = chars[j]
                    if c.isASCII, c.isNumber { j += 1; continue }
                    if c == ".", !sawDot, j + 1 < chars.count, chars[j + 1].isASCII, chars[j + 1].isNumber {
                        sawDot = true
                        j += 1
                        continue
                    }
                    break
                }
                return Decimal(string: String(chars[i..<j]), locale: Locale(identifier: "en_US_POSIX"))
            }
            i += 1
        }
        return nil
    }

    /// 比较两个版本；有一方读不出数字时按原文比（相同就是相同）。
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        switch (parse(a), parse(b)) {
        case let (x?, y?):
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
            return .orderedSame
        case (nil, nil):
            return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (nil, _?): return .orderedAscending
        case (_?, nil): return .orderedDescending
        }
    }

    /// 同一个版本（数字相同就算，写法不同也算）。
    static func same(_ a: String, _ b: String) -> Bool { compare(a, b) == .orderedSame }
}

// MARK: - 重复 / 多版本 / 损坏

/// 按文件看的字体信息（找重复用；一个 TTC 是一个文件）。
struct FontFileInfo: Hashable, Sendable, Identifiable {
    var path: String
    var location: FontLocation
    var size: Int64
    var modified: Date?
    var postScriptNames: [String]
    var version: String
    var family: String

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    /// 拾掇能不能停用 / 移到废纸篓（只有 ~/Library/Fonts 里的）。
    var isActionable: Bool { location == .user }
}

struct FontIssueGroup: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// 同一个 PostScript 名字、同一个版本，装了好几份。
        case duplicate
        /// 同一个 PostScript 名字、版本不同：建议留最新的。
        case versions
        /// 系统读不出来的字体文件。
        case damaged
    }

    var kind: Kind
    var title: String
    /// 建议保留的那一份（损坏的没有）。
    var keep: FontFileInfo?
    /// 建议停用的。
    var extras: [FontFileInfo]

    var id: String { kind.rawValue + ":" + (keep?.path ?? extras.first?.path ?? title) }
    var actionableExtras: [FontFileInfo] { extras.filter(\.isActionable) }
    var actionableBytes: Int64 { actionableExtras.reduce(0) { $0 + $1.size } }
}

enum FontIssueLogic {
    /// 找重复、多版本、损坏。只看 ~/Library/Fonts 和 /Library/Fonts（系统字体和拾掇停用的不算）。
    /// - 重复：PostScript 名字完全一样（TTC 按整组名字）、版本一样 → 留一份，其余建议停用。
    /// - 多版本：名字一样、版本不同 → 留版本最高的。
    /// 留哪份：有拾掇动不了的（/Library/Fonts）就留它（反正动不了，留它不会少什么）；
    /// 否则在 ~/Library/Fonts 里留最新改过的一份；再一样就留路径短的。
    static func issues(files: [FontFileInfo], damaged: [FontFileInfo]) -> [FontIssueGroup] {
        let considered = files.filter { $0.location == .user || $0.location == .local }
        var buckets: [String: [FontFileInfo]] = [:]
        for file in considered where !file.postScriptNames.isEmpty {
            let key = file.postScriptNames.sorted().joined(separator: "|")
            buckets[key, default: []].append(file)
        }
        var result: [FontIssueGroup] = []
        for (_, group) in buckets where group.count > 1 {
            let highest = group.max { FontVersion.compare($0.version, $1.version) == .orderedAscending }!
            let allSame = group.allSatisfy { FontVersion.same($0.version, highest.version) }
            let candidates = group.filter { FontVersion.same($0.version, highest.version) }
            let keep = preferredKeep(candidates)
            let extras = group.filter { $0.path != keep.path }
                .sorted { ($0.location.rawValue, $0.path) < ($1.location.rawValue, $1.path) }
            result.append(FontIssueGroup(kind: allSame ? .duplicate : .versions, title: keep.family, keep: keep, extras: extras))
        }
        for file in damaged where file.location == .user || file.location == .local {
            result.append(FontIssueGroup(kind: .damaged, title: file.fileName, keep: nil, extras: [file]))
        }
        return result.sorted { a, b in
            if a.kind != b.kind { return order(a.kind) < order(b.kind) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private static func order(_ kind: FontIssueGroup.Kind) -> Int {
        switch kind {
        case .duplicate: return 0
        case .versions: return 1
        case .damaged: return 2
        }
    }

    /// 一组同版本的副本里留哪份（见 issues 的说明）。
    static func preferredKeep(_ copies: [FontFileInfo]) -> FontFileInfo {
        if let locked = copies.filter({ !$0.isActionable }).sorted(by: { $0.path < $1.path }).first { return locked }
        return copies.sorted { a, b in
            let ma = a.modified ?? .distantPast
            let mb = b.modified ?? .distantPast
            if ma != mb { return ma > mb }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }.first!
    }
}

// MARK: - 停用清单（manifest）

/// 拾掇停用的一个字体文件：原来在哪、现在放在哪。
struct FontStoreEntry: Codable, Identifiable, Hashable, Sendable {
    enum Storage: String, Codable, Sendable {
        /// 放在拾掇字体仓库的 Disabled 文件夹里。
        case disabled
        /// 压缩存放（zip）。
        case archived
        /// 搬到移动硬盘 / 其他文件夹。
        case external
    }

    var id: UUID
    var originalPath: String
    var storedPath: String
    var storage: Storage
    var fileName: String
    /// 原文件大小。
    var size: Int64
    /// 压缩后的大小（压缩存放的才有）。
    var archivedSize: Int64?
    var family: String
    var localizedFamily: String
    var postScriptNames: [String]
    var styles: [String]
    var version: String
    var coversCJK: Bool
    var date: Date

    init(id: UUID = UUID(), originalPath: String, storedPath: String, storage: Storage = .disabled,
         size: Int64, family: String, localizedFamily: String = "", postScriptNames: [String] = [],
         styles: [String] = [], version: String = "", coversCJK: Bool = false, date: Date = Date()) {
        self.id = id
        self.originalPath = originalPath
        self.storedPath = storedPath
        self.storage = storage
        self.fileName = (originalPath as NSString).lastPathComponent
        self.size = size
        self.family = family
        self.localizedFamily = localizedFamily
        self.postScriptNames = postScriptNames
        self.styles = styles
        self.version = version
        self.coversCJK = coversCJK
        self.date = date
    }

    var location: FontLocation {
        switch storage {
        case .disabled: return .disabled
        case .archived: return .archived
        case .external: return .external
        }
    }

    var displayFamily: String { localizedFamily.isEmpty ? family : localizedFamily }
}

/// 字体集（Pro）：一组字体，可以临时启用，可以绑定项目文件夹。
struct FontSet: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 按 PostScript 名字记（文件换了位置也找得到）。
    var postScriptNames: [String]
    /// 绑定的项目文件夹。
    var boundFolders: [String]

    init(id: UUID = UUID(), name: String, postScriptNames: [String] = [], boundFolders: [String] = []) {
        self.id = id
        self.name = name
        self.postScriptNames = postScriptNames
        self.boundFolders = boundFolders
    }
}

/// 存到磁盘上的整份清单：停用的字体 + 字体集 + 压缩存放位置。
struct FontManifest: Codable, Equatable, Sendable {
    var version: Int = 1
    var entries: [FontStoreEntry] = []
    var sets: [FontSet] = []
    /// 压缩存放的位置（nil = 拾掇字体仓库里的 Archive）。
    var archiveFolder: String?

    static func encode(_ manifest: FontManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    /// 读不出来（文件坏了 / 新版本格式）返回 nil，调用方不要拿空清单覆盖它。
    static func decode(_ data: Data) -> FontManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FontManifest.self, from: data)
    }

    /// 停用文件夹里有、清单里没有的文件：补一条（原来的位置当作 ~/Library/Fonts 第一层）。
    static func orphanEntries(disabledFiles: [String], known: [FontStoreEntry], home: String) -> [FontStoreEntry] {
        let knownPaths = Set(known.map { FontPathRules.normalize($0.storedPath) })
        return disabledFiles.filter { !knownPaths.contains(FontPathRules.normalize($0)) }.map { path in
            let name = (path as NSString).lastPathComponent
            return FontStoreEntry(originalPath: (FontPathRules.userFonts(home: home) as NSString).appendingPathComponent(name),
                                  storedPath: path, size: 0, family: (name as NSString).deletingPathExtension)
        }
    }
}

// MARK: - 字体集绑定项目

enum FontSetBinding {
    /// 打开的文件夹是哪些字体集的项目文件夹（就是它，或在它里面）。
    static func sets(for folder: String, in sets: [FontSet]) -> [FontSet] {
        let f = FontPathRules.normalize(folder)
        return sets.filter { set in
            set.boundFolders.contains { bound in
                let b = FontPathRules.normalize(bound)
                return f == b || FontPathRules.isInside(f, folder: b)
            }
        }
    }

    /// 打开文件夹时怎么处理绑定的字体集。
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case ask, auto, off
        var id: String { rawValue }
    }

    static let modeKey = "fonts.projectActivation"
}

// MARK: - 搜索、排序、分组

enum FontLibraryLogic {
    /// 按家族分组（损坏的按文件名一组）。
    static func families(_ faces: [FontFace]) -> [FontFamily] {
        var buckets: [String: [FontFace]] = [:]
        var order: [String] = []
        for face in faces {
            let key = face.family.isEmpty ? face.fileName : face.family
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(face)
        }
        return order.map { key in
            let list = buckets[key]!.sorted { a, b in
                if a.location != b.location { return a.location.rawValue < b.location.rawValue }
                return a.style.localizedStandardCompare(b.style) == .orderedAscending
            }
            let display = list.first(where: { !$0.localizedFamily.isEmpty && $0.localizedFamily != $0.family })?.localizedFamily
                ?? list.first?.displayFamily ?? key
            return FontFamily(name: key, displayName: display, faces: list)
        }
    }

    /// 搜索：家族名（中文名 / 英文名）、PostScript 名字、样式名；中文名支持拼音和首字母（和命令面板一样的匹配）。
    static func matches(_ family: FontFamily, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let folded = PaletteMatcher.fold(q)
        var titles = [family.displayName, family.name]
        for face in family.faces.prefix(30) { titles.append(face.postScriptName) }
        for title in titles {
            if PaletteMatcher.fold(title).contains(folded) { return true }
        }
        // 拼音 / 首字母：只认靠谱的匹配（不认「跳着打」的模糊匹配，免得一搜一大片）。
        for title in [family.displayName, family.name] where Pinyin.containsHan(title) {
            if let score = PaletteMatcher.score(q, title: title), score >= 600 { return true }
        }
        return false
    }

    static func passes(_ family: FontFamily, filter: FontFilter) -> Bool {
        switch filter {
        case .all: return true
        case .cjk: return family.coversCJK
        case .user: return family.locations.contains(.user)
        case .local: return family.locations.contains(.local)
        case .system: return family.locations.contains(.system)
        case .stored: return family.locations.contains(where: \.isStoredByShiduo)
        }
    }

    static func sorted(_ families: [FontFamily], by key: FontSortKey) -> [FontFamily] {
        families.sorted { a, b in
            switch key {
            case .name:
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .size:
                if a.largestFileBytes != b.largestFileBytes { return a.largestFileBytes > b.largestFileBytes }
            case .total:
                if a.totalBytes != b.totalBytes { return a.totalBytes > b.totalBytes }
            case .added:
                let da = a.newestAdded ?? .distantPast
                let db = b.newestAdded ?? .distantPast
                if da != db { return da > db }
            }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    /// 字体集里的 PostScript 名字对应到现在的字形：同一个名字有好几份时，优先已经装着的，其次停用的、移动硬盘的、压缩的。
    static func resolve(_ postScriptNames: [String], in faces: [FontFace]) -> [FontFace] {
        let rank: [FontLocation: Int] = [.user: 0, .local: 1, .system: 2, .disabled: 3, .external: 4, .archived: 5]
        var best: [String: FontFace] = [:]
        for face in faces where !face.isDamaged {
            if let current = best[face.postScriptName], (rank[current.location] ?? 9) <= (rank[face.location] ?? 9) { continue }
            best[face.postScriptName] = face
        }
        return postScriptNames.compactMap { best[$0] }
    }
}

// MARK: - 中文字体

enum FontCoverage {
    /// 常用汉字（前 100 个左右）：90% 以上都有，才算「中文字体」（只带几个汉字的英文字体不算）。
    static let commonHanzi = "的一是了不在有人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处理府研"

    static func coversCJK(_ characters: CharacterSet) -> Bool {
        let scalars = Array(Set(commonHanzi.unicodeScalars))
        guard !scalars.isEmpty else { return false }
        let covered = scalars.filter { characters.contains($0) }.count
        return covered * 10 >= scalars.count * 9
    }

    static func coversCJK(font: CTFont) -> Bool {
        coversCJK(CTFontCopyCharacterSet(font) as CharacterSet)
    }

    /// 默认样张：中英文、数字都有。
    static let defaultSample = "拾掇 永和九年 岁在癸丑 The quick brown fox 0123"
}
