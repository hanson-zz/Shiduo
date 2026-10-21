import Foundation

/// 「拾掇风格」文件夹图标的纯逻辑（单元测试直接编译这个文件，只用 Foundation）。
enum FolderArtLogic {
    /// 有自己图标的系统文件夹：拾掇文件夹 + 一个 SF Symbol。
    enum Special: String, CaseIterable {
        case home, desktop, documents, downloads, pictures, movies, music, applications, iCloudDrive

        var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .desktop: return "menubar.dock.rectangle"
            case .documents: return "doc.text.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .pictures: return "photo.fill"
            case .movies: return "film.fill"
            case .music: return "music.note"
            case .applications: return "square.grid.3x3.fill"
            case .iCloudDrive: return "icloud.fill"
            }
        }
    }

    /// 这个路径是不是个人文件夹、桌面、文稿……（只比路径，不读磁盘）。
    static func special(_ path: String, home: String) -> Special? {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        var h = home
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        if p == "/Applications" || p == "/System/Applications" { return .applications }
        guard !h.isEmpty, h != "/" else { return nil }
        switch p {
        case h: return .home
        case h + "/Desktop": return .desktop
        case h + "/Documents": return .documents
        case h + "/Downloads": return .downloads
        case h + "/Pictures": return .pictures
        case h + "/Movies": return .movies
        case h + "/Music": return .music
        case h + "/Applications": return .applications
        case h + "/Library/Mobile Documents/com~apple~CloudDocs": return .iCloudDrive
        default: return nil
        }
    }

    /// 访达信息（com.apple.FinderInfo 扩展属性，32 字节）里「有自定义图标」那一位（kHasCustomIcon = 0x0400，大端）。
    static func hasCustomIconFlag(_ finderInfo: [UInt8]) -> Bool {
        guard finderInfo.count >= 10 else { return false }
        let flags = UInt16(finderInfo[8]) << 8 | UInt16(finderInfo[9])
        return flags & 0x0400 != 0
    }

    /// 栅格化的像素档位：32 / 64 / 128 / 256 / 512，同一档的图标共用一张缓存图。
    static func pixelBucket(side: Double, scale: Double) -> Int {
        let need = Int((max(side, 1) * max(scale, 1)).rounded(.up))
        for edge in [32, 64, 128, 256] where need <= edge { return edge }
        return 512
    }

    /// 栅格化缓存的键：颜色 + 像素档位 + 深浅色。叠加层另外画，不进键，缓存最多几十张。
    static func cacheKey(hex: String, pixels: Int, dark: Bool) -> String {
        "\(hex.uppercased())#\(pixels)#\(dark ? "d" : "l")"
    }
}
