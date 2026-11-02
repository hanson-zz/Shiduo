import AppKit
import CoreText
import Foundation

/// 字体库列表 / 信息页要的「另外读」的信息：厂商、设计师、字数、版权……
/// 扫描时不读（字体多了会慢），用到哪些家族才在后台读哪些，读过的按字形缓存（重新扫描后路径变了自然会重读）。
@MainActor
final class FontExtraInfoStore: ObservableObject {
    static let shared = FontExtraInfoStore()

    @Published private(set) var cache: [String: FontExtraInfo] = [:]
    private var pending = Set<String>()

    private init() {}

    func info(for face: FontFace?) -> FontExtraInfo? {
        guard let face else { return nil }
        return cache[face.id]
    }

    /// 在后台读还没读过的字形（每 150 个更新一次界面）。
    func load(_ faces: [FontFace]) {
        let need = faces.filter { cache[$0.id] == nil && !pending.contains($0.id) }
        guard !need.isEmpty else { return }
        pending.formUnion(need.map(\.id))
        Task {
            var start = 0
            while start < need.count {
                let chunk = Array(need[start..<min(start + 150, need.count)])
                let result = await Task.detached(priority: .utility) {
                    chunk.map { ($0.id, FontExtraReader.read($0)) }
                }.value
                for (id, value) in result { cache[id] = value }
                start += 150
            }
            pending.subtract(need.map(\.id))
        }
    }
}

enum FontExtraReader {
    /// 读一个字形的 name 表信息和字数（读不出来的字体返回空的，不再重试）。
    static func read(_ face: FontFace) -> FontExtraInfo {
        guard let nsFont = FontPreviewCache.font(for: face, size: 24) else { return FontExtraInfo() }
        let font = nsFont as CTFont
        func name(_ key: CFString) -> String {
            (CTFontCopyName(font, key) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return FontExtraInfo(
            manufacturer: name(kCTFontManufacturerNameKey),
            designer: name(kCTFontDesignerNameKey),
            glyphCount: CTFontGetGlyphCount(font),
            copyright: String(name(kCTFontCopyrightNameKey).prefix(600)),
            trademark: String(name(kCTFontTrademarkNameKey).prefix(300)),
            descriptionText: String(name(kCTFontDescriptionNameKey).prefix(1000))
        )
    }
}
