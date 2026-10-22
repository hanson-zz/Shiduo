import Foundation

/// 按文件名认出第三方截图工具存的截图（微信、QQ、Snipaste、CleanShot、飞书、钉钉……）。
/// 系统截图有 Spotlight 的 kMDItemIsScreenCapture 标记，第三方工具的没有，以前「截图」里看不到它们。
/// 只看文件名，不读文件；只对图片生效。纯逻辑，有单元测试，Spotlight 查询条件也从这里生成，两边保持一致。
enum ScreenshotNameRules {
    enum Rule: Equatable {
        /// 文件名以它开头（不区分大小写）。
        case prefix(String)
        /// 以 head 开头，后面某处还有 tail（WeChat…截图…）。
        case prefixThenContains(String, String)
        /// 以它开头，紧跟（可选的一个 空格 / _ / -）和年份 20xx：Capture_2024…、Snip20241022…。
        /// 这类名字太常见，不带日期的不算，免得误认。
        case prefixThenDate(String)
    }

    static let rules: [Rule] = [
        .prefix("微信截图_"),
        .prefixThenContains("wechat", "截图"),
        .prefix("qq截图"),
        .prefixThenDate("qq"),
        .prefix("snipaste_"),
        .prefix("cleanshot "),
        .prefix("xnip"),
        .prefix("ishot"),
        .prefix("pixpin_"),
        .prefix("shottr"),
        .prefix("截屏"),
        .prefix("截图"),
        .prefix("屏幕截图"),
        .prefix("屏幕快照"),
        .prefix("screenshot"),      // 也包括 ScreenShot_…
        .prefix("screen shot"),
        .prefix("quickshot-"),
        .prefixThenDate("capture"),
        .prefixThenDate("snip"),
        .prefix("飞书截图"),
        .prefixThenContains("lark", "截图"),
        .prefix("钉钉截图"),
        .prefixThenContains("dingtalk", "截图"),
        .prefixThenDate("dingtalk"),
    ]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]

    private static let separators: Set<Character> = [" ", "_", "-"]

    /// 文件名像截图（不管是不是图片）。
    static func nameMatches(_ name: String) -> Bool {
        let lower = name.lowercased()
        return rules.contains { matches(lower, $0) }
    }

    /// 是截图：系统标记过，或者是图片且文件名像第三方截图。
    static func isScreenshot(name: String, typeTree: [String], systemFlag: Bool) -> Bool {
        if systemFlag { return true }
        guard isImage(name: name, typeTree: typeTree) else { return false }
        return nameMatches(name)
    }

    static func isImage(name: String, typeTree: [String]) -> Bool {
        typeTree.contains("public.image") || imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func matches(_ lower: String, _ rule: Rule) -> Bool {
        switch rule {
        case .prefix(let p):
            return lower.hasPrefix(p)
        case .prefixThenContains(let head, let tail):
            guard lower.hasPrefix(head) else { return false }
            return lower.dropFirst(head.count).contains(tail)
        case .prefixThenDate(let p):
            guard lower.hasPrefix(p) else { return false }
            var rest = Substring(lower.dropFirst(p.count))
            if let first = rest.first, separators.contains(first) { rest = rest.dropFirst() }
            let digits = rest.prefix(4)
            guard digits.count == 4, digits.hasPrefix("20"), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber)
            else { return false }
            return true
        }
    }

    /// Spotlight 的 kMDItemFSName LIKE[c] 通配符（和 rules 对应；日期类只能写到「20」，结果再用 isScreenshot 过滤）。
    static var spotlightPatterns: [String] {
        rules.flatMap { rule -> [String] in
            switch rule {
            case .prefix(let p): return ["\(p)*"]
            case .prefixThenContains(let head, let tail): return ["\(head)*\(tail)*"]
            case .prefixThenDate(let p): return ["\(p)20*"] + separators.sorted().map { "\(p)\($0)20*" }
            }
        }
    }
}
