import Foundation

/// 资料库默认会看的几个个人文件夹。
enum LibraryFolder: String, CaseIterable, Identifiable, Hashable, Sendable {
    case desktop, documents, downloads, pictures, movies, music, iCloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return String(localized: "桌面")
        case .documents: return String(localized: "文稿")
        case .downloads: return String(localized: "下载")
        case .pictures: return String(localized: "图片")
        case .movies: return String(localized: "影片")
        case .music: return String(localized: "音乐")
        case .iCloud: return String(localized: "iCloud 云盘")
        }
    }

    var symbol: String {
        switch self {
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc"
        case .downloads: return "arrow.down.circle"
        case .pictures: return "photo"
        case .movies: return "film"
        case .music: return "music.note"
        case .iCloud: return "icloud"
        }
    }

    /// iCloud 云盘在磁盘上的位置（相对个人文件夹）。
    static let iCloudRelative = "Library/Mobile Documents/com~apple~CloudDocs"
    /// 所有 iCloud 容器的上级（访达「iCloud 云盘」里的 Pages / Numbers / Keynote 等 App 文件夹在这里的 <容器>/Documents）。
    static let mobileDocumentsRelative = "Library/Mobile Documents"

    /// 这个文件夹在磁盘上的位置。「桌面与文稿」存到 iCloud 时，文件实际在 iCloud 云盘里的 Desktop / Documents，两处都算。
    func paths(home: String) -> [String] {
        let h = LibraryScope.standardize(home)
        let cloud = h + "/" + Self.iCloudRelative
        switch self {
        case .desktop: return [h + "/Desktop", cloud + "/Desktop"]
        case .documents: return [h + "/Documents", cloud + "/Documents"]
        case .downloads: return [h + "/Downloads"]
        case .pictures: return [h + "/Pictures"]
        case .movies: return [h + "/Movies"]
        case .music: return [h + "/Music"]
        // 整个 Mobile Documents：iCloud 云盘本身 + 各 App 容器的 Documents（容器里别的东西由 isNoise 排除）。
        case .iCloud: return [h + "/" + Self.mobileDocumentsRelative]
        }
    }
}

/// 资料库范围：「只算你自己的文件」。纯逻辑（只依赖 Foundation），单元测试直接调用。
///
/// 一个文件算不算资料库里的：看离它最近（最深）的那条规则——
/// 打开的默认文件夹 / 自己加的文件夹 = 算；关掉的默认文件夹 / 设成「不在资料库中显示」的文件夹 = 不算；
/// 同样深时「不显示」优先。所以可以在「文稿」里排除一个文件夹，再把其中一个子文件夹加回来。
/// 另外应用、系统、缓存、隐藏文件夹和各种素材库 / 工程包里面的文件一律不算。
struct LibraryScope: Equatable, Sendable {
    var home: String
    var disabled: Set<LibraryFolder> = []
    var added: [String] = []
    var excluded: [String] = []
    var hideSmallImages = true

    init(home: String, disabled: Set<LibraryFolder> = [], added: [String] = [], excluded: [String] = [], hideSmallImages: Bool = true) {
        self.home = Self.standardize(home)
        self.disabled = disabled
        self.added = added.map(Self.standardize)
        self.excluded = excluded.map(Self.standardize)
        self.hideSmallImages = hideSmallImages
    }

    /// 去掉末尾的「/」、「.」「..」（不解析符号链接，和 Spotlight 给的路径写法一致）。
    static func standardize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 应用、系统、缓存、隐藏文件夹、素材库和工程包里面的文件：即使在个人文件夹里也不算。
    static let noiseMarkers = [
        "/Library/", "/.", "/node_modules/", "/DerivedData/", "/Pods/",
        ".photoslibrary/", ".app/", ".bundle/", ".framework/", ".xcassets/",
        ".fcpbundle/", ".imovielibrary/", ".lrdata/", ".lrcat-data/", ".git/",
        ".tvlibrary/", ".musiclibrary/", ".photolibrary/", ".aplibrary/", ".band/",
        ".logicx/", ".xcodeproj/", ".xcworkspace/", ".pkg/", ".plugin/", ".kext/",
    ]

    var iCloudRoot: String { home + "/" + LibraryFolder.iCloudRelative }

    var mobileDocumentsRoot: String { home + "/" + LibraryFolder.mobileDocumentsRelative }

    /// 只看「自己的那一段」路径再判断：
    /// - iCloud 云盘里的文件去掉 ~/Library/Mobile Documents/com~apple~CloudDocs，
    ///   App 容器（访达 iCloud 云盘里的 Pages、Numbers……）去掉 ~/Library/Mobile Documents/<容器>/Documents，
    ///   不然路径里的「/Library/」会把整个 iCloud 云盘当成系统文件；容器里 Documents 以外的东西算系统文件。
    /// - 自己加的文件夹里的文件从那个文件夹开始算（加了 ~/Library 里的某个文件夹也能看到里面的文件）。
    func isNoise(_ path: String) -> Bool {
        var base: String? = nil
        for root in added where PathLogic.isSameOrInside(path, root) {
            if base == nil || root.count > base!.count { base = root }
        }
        let mobile = mobileDocumentsRoot
        if PathLogic.isSameOrInside(path, mobile) {
            let parts = path.dropFirst(mobile.count).split(separator: "/", omittingEmptySubsequences: true)
            if let container = parts.first {
                var containerBase: String? = nil
                if container == "com~apple~CloudDocs" {
                    containerBase = mobile + "/" + String(container)
                } else if parts.count >= 2, parts[1] == "Documents" {
                    containerBase = mobile + "/" + String(container) + "/Documents"
                } else if base == nil {
                    return true
                }
                if let containerBase, containerBase.count > (base?.count ?? 0) { base = containerBase }
            }
        }
        if base == nil, PathLogic.isSameOrInside(path, home) { base = home }
        let rest = base.map { String(path.dropFirst($0.count)) } ?? path
        return Self.noiseMarkers.contains { rest.contains($0) }
    }

    /// 打开的默认文件夹（磁盘上的位置）。
    var enabledDefaultPaths: [String] {
        LibraryFolder.allCases.filter { !disabled.contains($0) }.flatMap { $0.paths(home: home) }
    }

    /// 关掉的默认文件夹。
    var disabledDefaultPaths: [String] {
        LibraryFolder.allCases.filter { disabled.contains($0) }.flatMap { $0.paths(home: home) }
    }

    /// 要查的文件夹（Spotlight 的 searchScopes）：打开的默认文件夹 + 自己加的；
    /// 去掉重复的和已经被上级包含的。exists 用来去掉磁盘上不存在的（测试里可以传固定答案）。
    func searchRoots(exists: (String) -> Bool) -> [String] {
        var roots: [String] = []
        for path in enabledDefaultPaths + added where exists(path) && includes(path, checkNoise: false) {
            if roots.contains(where: { PathLogic.isSameOrInside(path, $0) }) { continue }
            roots.removeAll { PathLogic.isSameOrInside($0, path) }
            roots.append(path)
        }
        return roots
    }

    /// 这个文件夹被设成了「不在资料库中显示」（它自己，不看上级）。
    func isExcludedFolder(_ path: String) -> Bool {
        excluded.contains(Self.standardize(path))
    }

    /// 这个文件算不算资料库里的文件。
    func includes(_ rawPath: String, checkNoise: Bool = true) -> Bool {
        let path = Self.standardize(rawPath)
        if checkNoise && isNoise(path) { return false }
        // 最深的那条规则说了算；同样深时「不算」优先。
        var best: (depth: Int, included: Bool)? = nil
        func consider(_ roots: [String], included: Bool) {
            for root in roots where PathLogic.isSameOrInside(path, root) {
                let depth = root.count
                if let current = best {
                    if depth > current.depth || (depth == current.depth && !included) {
                        best = (depth, included)
                    }
                } else {
                    best = (depth, included)
                }
            }
        }
        consider(enabledDefaultPaths, included: true)
        consider(added, included: true)
        consider(disabledDefaultPaths, included: false)
        consider(excluded, included: false)
        return best?.included ?? false
    }

    /// 「隐藏小图标」：宽和高都知道、而且都小于 100 像素的图片（应用图标、网页小图、表情）。没有尺寸信息的不隐藏。
    static func isSmallImage(width: Int?, height: Int?) -> Bool {
        guard let width, let height, width > 0, height > 0 else { return false }
        return width < 100 && height < 100
    }

    // MARK: 设置里的改动

    /// 「不在资料库中显示」：加进排除列表，并去掉里面已有的更细的排除（被上级排除就够了）。
    mutating func exclude(_ rawPath: String) {
        let path = Self.standardize(rawPath)
        excluded.removeAll { PathLogic.isSameOrInside($0, path) }
        added.removeAll { $0 == path }
        excluded.append(path)
    }

    /// 「在资料库中显示」：去掉它自己的排除；还不在范围里（默认文件夹之外，或在一个被排除的文件夹里面）就加进来。
    mutating func include(_ rawPath: String) {
        let path = Self.standardize(rawPath)
        excluded.removeAll { $0 == path }
        if !includes(path, checkNoise: false), !added.contains(path) {
            added.append(path)
        }
    }
}

/// 类别顶部的小分类（图片：照片 / 截图 / 设计稿……）。纯逻辑，单元测试直接调用。
enum LibrarySub: String, CaseIterable, Identifiable, Hashable, Sendable {
    // 图片
    case photo, screenshot, design
    // 视频
    case screenRecording, footage
    // 文稿
    case pdf, word, excel, slides, text
    // 音乐
    case song, recording
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return String(localized: "照片")
        case .screenshot: return String(localized: "截图")
        case .design: return String(localized: "设计稿")
        case .screenRecording: return String(localized: "录屏")
        case .footage: return String(localized: "拍摄")
        case .pdf: return "PDF"
        case .word: return "Word"
        case .excel: return "Excel"
        case .slides: return "PPT"
        case .text: return String(localized: "文本")
        case .song: return String(localized: "歌曲")
        case .recording: return String(localized: "录音")
        case .other: return String(localized: "其他")
        }
    }

    /// 这个类别有哪些小分类（没有的返回空，不显示小分类）。
    static func subs(for category: FileCategory) -> [LibrarySub] {
        switch category {
        case .images: return [.photo, .screenshot, .design, .other]
        case .videos: return [.screenRecording, .footage, .other]
        case .documents: return [.pdf, .word, .excel, .slides, .text, .other]
        case .music: return [.song, .recording, .other]
        default: return []
        }
    }

    /// 设计稿的扩展名：有些（.sketch、.fig、.xd……）系统不认为是图片，也要出现在「全部图片」里。
    static let designExtensions = ["psd", "psb", "ai", "sketch", "fig", "xd", "afdesign", "afphoto", "eps", "svg"]
    static let rawExtensions = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw", "heic", "heif"]

    /// 分类用到的元数据。
    struct Fields: Sendable {
        var name: String
        var typeTree: [String] = []
        var isScreenCapture = false
        var acquisitionMake: String? = nil
        var acquisitionModel: String? = nil
        var authors: [String] = []
        var album: String? = nil

        init(name: String, typeTree: [String] = [], isScreenCapture: Bool = false,
             acquisitionMake: String? = nil, acquisitionModel: String? = nil,
             authors: [String] = [], album: String? = nil) {
            self.name = name
            self.typeTree = typeTree
            self.isScreenCapture = isScreenCapture
            self.acquisitionMake = acquisitionMake
            self.acquisitionModel = acquisitionModel
            self.authors = authors
            self.album = album
        }

        var ext: String { (name as NSString).pathExtension.lowercased() }
        var hasCamera: Bool {
            !(acquisitionMake ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                || !(acquisitionModel ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        var hasArtist: Bool {
            authors.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                || !(album ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// 读不读类型树（只有文稿按扩展名认不出来时才需要，省得每个文件都多读一项元数据）。
    static func needsTypeTree(_ category: FileCategory, name: String) -> Bool {
        category == .documents && classify(Fields(name: name), in: .documents) == .other
    }

    static func classify(_ f: Fields, in category: FileCategory) -> LibrarySub {
        let ext = f.ext
        let lower = f.name.lowercased()
        switch category {
        case .images:
            if designExtensions.contains(ext) { return .design }
            if f.isScreenCapture { return .screenshot }
            if f.hasCamera || rawExtensions.contains(ext) { return .photo }
            return .other
        case .videos:
            if f.isScreenCapture || f.name.contains("屏幕录制") || f.name.contains("录屏")
                || lower.contains("screen recording") { return .screenRecording }
            if f.hasCamera { return .footage }
            return .other
        case .documents:
            switch ext {
            case "pdf": return .pdf
            case "doc", "docx", "dot", "dotx", "pages", "odt", "wps": return .word
            case "xls", "xlsx", "xlsm", "csv", "numbers", "ods", "et": return .excel
            case "ppt", "pptx", "pps", "ppsx", "key", "odp", "dps": return .slides
            case "txt", "md", "markdown", "rtf", "rtfd", "text": return .text
            default: break
            }
            let tree = Set(f.typeTree)
            if tree.contains("com.adobe.pdf") { return .pdf }
            if tree.contains("public.spreadsheet") { return .excel }
            if tree.contains("public.presentation") { return .slides }
            if tree.contains("org.openxmlformats.wordprocessingml.document") || tree.contains("com.microsoft.word.doc")
                || tree.contains("com.apple.iwork.pages.sffpages") || tree.contains("com.apple.iwork.pages.pages") { return .word }
            if tree.contains("public.plain-text") || tree.contains("public.rtf") || tree.contains("net.daringfireball.markdown") { return .text }
            return .other
        case .music:
            if f.hasArtist { return .song }
            let stem = (lower as NSString).deletingPathExtension
            let named = f.name.contains("新录音") || f.name.contains("录音") || stem.contains("recording")
                || stem.hasPrefix("new recording") || stem.hasPrefix("voice memo")
            if named || ["m4a", "caf", "amr", "aac", "3gp", "opus"].contains(ext) { return .recording }
            return .other
        default:
            return .other
        }
    }
}
