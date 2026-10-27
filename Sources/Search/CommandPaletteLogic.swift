import Foundation

/// 命令面板（⌃⌘P）里的一条：菜单命令、页面、排序、清理卡片、设置页、收藏、最近去过的文件夹。
/// 真正要做的事由界面那边按 id 对上（这里只放能单元测试的部分）。
struct PaletteItem: Identifiable, Equatable, Sendable {
    enum Section: String, CaseIterable, Sendable {
        case recent, favorite, action, go, view, sort, cleanup, settings
    }

    let id: String
    let title: String
    let section: Section
    var subtitle: String? = nil
    /// 「⌘L」这种快捷键提示。
    var shortcut: String? = nil
    var symbol: String = "command"
    /// 别的叫法（英文名、同义词），也参与匹配。
    var keywords: [String] = []
}

/// 命令面板的匹配和排序：不分大小写 / 重音；中文标题可以打全拼或拼音首字母（「znql」→「智能清理」、「ys」→「压缩」）；
/// 也可以跳着打（「xjwj」→「新建文件夹」）。
enum PaletteMatcher {
    /// 一个标题预先算好的几种写法（建索引时算一次，按标题缓存）。
    struct Key: Equatable, Sendable {
        /// 原文折叠后（小写、去重音、全角变半角）。
        let folded: String
        /// 全拼连在一起（「zhinengqingli」），英文原样。
        let pinyin: String
        /// 每个字 / 每个英文单词的首字母（「znql」）。
        let initials: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Key] = [:]

    /// 汉字换成拼音：kCFStringTransformToLatin 再去掉声调。按字分开（「zhì néng」→「zhi neng」）。
    static func latin(_ text: String) -> String {
        let s = NSMutableString(string: text)
        CFStringTransform(s, nil, kCFStringTransformToLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        return (s as String).lowercased()
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// 建索引：同一个标题只转一次拼音。
    static func key(for title: String) -> Key {
        lock.lock()
        if let hit = cache[title] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let folded = fold(title)
        let roman = latin(title)
        // 按「不是字母数字」切成一个个音节 / 单词。
        let words = roman.split { !($0.isLetter || $0.isNumber) }.map { String($0).filter { $0.isASCII } }.filter { !$0.isEmpty }
        let key = Key(folded: folded,
                      pinyin: words.joined(),
                      initials: String(words.compactMap(\.first)))
        lock.lock()
        cache[title] = key
        lock.unlock()
        return key
    }

    /// 分数越高越靠前；对不上返回 nil。多个词（空格分开）要每个都对得上。
    static func score(_ query: String, title: String, keywords: [String] = []) -> Int? {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let keys = [key(for: title)] + keywords.map { key(for: $0) }
        var total = 0
        for word in words {
            var best: Int?
            for (index, key) in keys.enumerated() {
                guard var s = score(word: word, key: key) else { continue }
                if index > 0 { s = s * 9 / 10 }   // 别名比标题本身低一点
                best = max(best ?? s, s)
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    /// 一个词对一个标题。
    static func score(word: String, key: Key) -> Int? {
        let q = word
        let t = key.folded
        // 越短的标题完全对上越靠前。
        let shortBonus = max(0, 40 - t.count)
        if t == q { return 1200 + shortBonus }
        if t.hasPrefix(q) { return 1000 + shortBonus }
        if !key.initials.isEmpty, key.initials == q { return 950 + shortBonus }
        if !key.initials.isEmpty, key.initials.hasPrefix(q), q.count >= 2 { return 900 + shortBonus }
        if let range = t.range(of: q) {
            // 在词的开头（前面是空格 / 符号）更好。
            let atWordStart = range.lowerBound == t.startIndex || !t[t.index(before: range.lowerBound)].isLetter
            return (atWordStart ? 850 : 800) + shortBonus
        }
        if !key.pinyin.isEmpty, q.allSatisfy({ $0.isASCII }) {
            if key.pinyin.hasPrefix(q) { return 760 + shortBonus }
            if q.count >= 2, key.pinyin.contains(q) { return 650 + shortBonus }
            if q.count >= 2, key.initials.contains(q) { return 600 + shortBonus }
        }
        // 跳着打：每个字母按顺序出现在标题 / 首字母 / 全拼里。
        if let s = subsequenceScore(q, in: t) { return 300 + s + shortBonus }
        if q.count >= 2, let s = subsequenceScore(q, in: key.initials) { return 280 + s + shortBonus }
        if q.count >= 3, let s = subsequenceScore(q, in: key.pinyin) { return 150 + s + shortBonus }
        return nil
    }

    /// q 的字符按顺序都在 text 里：连着的越多、越靠前分越高；对不上返回 nil。
    static func subsequenceScore(_ q: String, in text: String) -> Int? {
        guard !q.isEmpty, !text.isEmpty else { return nil }
        let t = Array(text)
        var ti = 0
        var score = 0
        var run = 0
        var firstHit: Int?
        for ch in q {
            var found = false
            while ti < t.count {
                if t[ti] == ch {
                    if firstHit == nil { firstHit = ti }
                    run += 1
                    score += 10 + run * 5
                    ti += 1
                    found = true
                    break
                }
                run = 0
                ti += 1
            }
            if !found { return nil }
        }
        return score - min(firstHit ?? 0, 20) * 2
    }

    /// 按分数排序（一样高时保持原来的顺序）；空查询原样返回。
    static func rank(_ items: [PaletteItem], query: String, limit: Int = 60) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(items.prefix(limit)) }
        var scored: [(item: PaletteItem, score: Int, order: Int)] = []
        for (order, item) in items.enumerated() {
            if let s = score(trimmed, title: item.title, keywords: item.keywords) {
                scored.append((item, s, order))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.item)
    }

    /// 排好的结果按分区成组：分区按它里面最靠前那一条的位置排，组内保持排好的顺序（和效果图一样「操作 / 前往 / 设置」分段）。
    static func grouped(_ ranked: [PaletteItem]) -> [(section: PaletteItem.Section, items: [PaletteItem])] {
        var order: [PaletteItem.Section] = []
        var buckets: [PaletteItem.Section: [PaletteItem]] = [:]
        for item in ranked {
            if buckets[item.section] == nil { order.append(item.section) }
            buckets[item.section, default: []].append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
