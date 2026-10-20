import Foundation

/// 资料库里的文件分类。只依赖 Foundation，单元测试也会编译它。
enum FileCategory: String, CaseIterable, Identifiable, Hashable {
    case recents
    case images
    case videos
    case music
    case documents
    case archives
    case apps

    var id: String { rawValue }

    /// 首页统计卡片上显示的分类（“最近使用”不是一种类型，不参与统计）。
    static let dashboard: [FileCategory] = [.images, .videos, .music, .documents, .archives, .apps]

    var title: String {
        switch self {
        case .recents: return String(localized: "最近使用")
        case .images: return String(localized: "图片")
        case .videos: return String(localized: "视频")
        case .music: return String(localized: "音乐")
        case .documents: return String(localized: "文稿")
        case .archives: return String(localized: "压缩包")
        case .apps: return String(localized: "应用程序")
        }
    }

    /// 侧边栏「资料库」和列表标题用的名字：「全部图片」这种，和「位置」里的「图片」文件夹区分开
    /// （资料库是整台 Mac 里按类型搜出来的，文件夹只是 ~/Pictures 这一个地方）。
    var libraryTitle: String {
        switch self {
        case .images: return String(localized: "全部图片")
        case .videos: return String(localized: "全部视频")
        case .music: return String(localized: "全部音乐")
        case .documents: return String(localized: "全部文稿")
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .recents: return "clock"
        case .images: return "photo"
        case .videos: return "film"
        case .music: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .apps: return "app.badge"
        }
    }

    /// Spotlight 内容类型（UTI），匹配 kMDItemContentTypeTree 中的任意一项即可。
    var contentTypes: [String] {
        switch self {
        case .recents: return []
        case .images: return ["public.image"]
        case .videos: return ["public.movie"]
        case .music: return ["public.audio"]
        case .documents:
            return [
                "com.adobe.pdf",
                "public.presentation",
                "public.spreadsheet",
                "org.openxmlformats.wordprocessingml.document",
                "com.microsoft.word.doc",
                "public.rtf",
                "com.apple.rtfd",
                "com.apple.iwork.pages.sffpages",
                "com.apple.iwork.pages.pages",
                "net.daringfireball.markdown",
                "org.idpf.epub-container",
            ]
        case .archives: return ["public.archive", "public.disk-image"]
        case .apps: return ["com.apple.application-bundle"]
        }
    }

    /// 根据一个文件的类型树判断它属于哪个分类。
    static func classify(typeTree: [String]) -> FileCategory? {
        let tree = Set(typeTree)
        for category in [FileCategory.apps, .images, .videos, .music, .archives, .documents] {
            if category.contentTypes.contains(where: { tree.contains($0) }) {
                return category
            }
        }
        return nil
    }
}
