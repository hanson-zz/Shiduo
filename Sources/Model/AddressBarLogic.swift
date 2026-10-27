import Foundation

/// 可输入地址栏（⌘L）：把输入的文字换成路径、拆出「在哪个文件夹里补全」和「已经打了的半个名字」、给补全排序（纯逻辑，单元测试覆盖）。
enum AddressBarLogic {
    /// 补全下拉最多列这么多个。
    static let suggestionLimit = 40

    /// 去掉首尾空白和成对的引号（从终端、聊天里拷来的路径常带引号）；file:// 地址换成路径。
    static func cleaned(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("'", "'"), ("“", "”"), ("「", "」")] {
            if text.count >= 2, text.hasPrefix(open), text.hasSuffix(close) {
                text = String(text.dropFirst(open.count).dropLast(close.count))
            }
        }
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
            text = url.path
        }
        // 终端里拷来的「带反斜杠的空格」。
        if text.contains("\\ ") { text = text.replacingOccurrences(of: "\\ ", with: " ") }
        return text
    }

    /// 输入换成绝对路径：支持 /绝对路径、~、~/…、相对当前文件夹（没有当前文件夹时相对个人文件夹），
    /// 去掉 . 和 ..、多余的 /。空输入返回 nil。不读磁盘。
    static func resolve(_ input: String, current: String?, home: String) -> String? {
        let text = cleaned(input)
        guard !text.isEmpty else { return nil }
        let raw: String
        if text == "~" {
            raw = home
        } else if text.hasPrefix("~/") {
            raw = home + "/" + text.dropFirst(2)
        } else if text.hasPrefix("/") {
            raw = text
        } else {
            raw = (current ?? home) + "/" + text
        }
        return normalize(raw)
    }

    /// 只按文字整理路径（不碰磁盘，不解析替身 / 符号链接）。
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 输入框里显示的写法：个人文件夹写成 ~，文件夹结尾带 /，方便接着打下一层。
    static func displayPath(_ path: String, home: String) -> String {
        let clean = normalize(path)
        var text = clean
        if clean == home {
            text = "~"
        } else if clean.hasPrefix(home + "/") {
            text = "~" + clean.dropFirst(home.count)
        }
        return text == "/" ? "/" : text + "/"
    }

    /// 拆成「最后一个 / 之前（含 /）」和「正在打的半个名字」。
    /// 「~/文稿/品」→（"~/文稿/", "品"）；「~/文稿/」→（"~/文稿/", ""）；「品」→（"", "品"）；「~」→（"~/", ""）。
    static func split(_ input: String) -> (directory: String, partial: String) {
        let text = cleaned(input)
        if text == "~" { return ("~/", "") }
        guard let slash = text.lastIndex(of: "/") else { return ("", text) }
        let directory = String(text[...slash])
        let partial = String(text[text.index(after: slash)...])
        return (directory, partial)
    }

    /// 补全时要列哪个文件夹（绝对路径）。
    static func listingFolder(for input: String, current: String?, home: String) -> String {
        let directory = split(input).directory
        if directory.isEmpty { return normalize(current ?? home) }
        return resolve(directory, current: current, home: home) ?? normalize(current ?? home)
    }

    /// 选中一个补全项后输入框里的文字：前面的部分保持用户打的样子，后面接上名字和 /。
    static func completion(for input: String, picking name: String) -> String {
        split(input).directory + name + "/"
    }

    // MARK: - 补全排序

    enum MatchKind: Int, Comparable {
        case exact = 0
        case prefix
        case pinyin
        case contains

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 不分大小写、不分重音、不分全角半角。
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// 名字能不能补全刚打的半个名字：完全一样 > 开头一样 > 拼音（全拼 / 首字母，如「pp」→「品牌提案」）> 中间包含。
    static func match(name: String, partial: String) -> MatchKind? {
        guard !partial.isEmpty else { return .prefix }
        let n = fold(name)
        let p = fold(partial)
        if n == p { return .exact }
        if n.hasPrefix(p) { return .prefix }
        if Pinyin.looksLikePinyin(p) || (p.count == 1 && p.first.map { $0 >= "a" && $0 <= "z" } == true) {
            if Pinyin.containsHan(name), Pinyin.matches(name, query: p) { return .pinyin }
        }
        if n.contains(p) { return .contains }
        return nil
    }

    /// 给子文件夹名字排序、筛选：先按匹配程度，再按访达的名字顺序。以 . 开头的隐藏文件夹只有打了 . 才列。
    static func rank(_ names: [String], partial: String, limit: Int = suggestionLimit) -> [String] {
        let showHidden = partial.hasPrefix(".")
        var scored: [(name: String, kind: MatchKind)] = []
        for name in names {
            if !showHidden, name.hasPrefix(".") { continue }
            if let kind = match(name: name, partial: partial) { scored.append((name, kind)) }
        }
        scored.sort {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return scored.prefix(limit).map(\.name)
    }
}
