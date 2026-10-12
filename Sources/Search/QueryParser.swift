import Foundation

/// 把“上周超过5MB的pdf”“large videos from youtube.com this month”这样的句子
/// 解析成结构化的筛选条件。纯逻辑，不访问磁盘，便于单元测试。
struct QueryParser {
    var now: Date = Date()
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // 一周从周一开始
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    // MARK: - 公共入口

    func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        var s = " " + input.lowercased()
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: ",", with: " ") + " "

        parseDevice(&s, into: &query)
        parseSource(&s, into: &query)
        parseSize(&s, into: &query)
        parseDate(&s, into: &query)
        parseKinds(&s, into: &query)
        query.text = cleanResidue(s)
        return query
    }

    // MARK: - 正则工具

    /// 找到第一个匹配，把它从字符串里抹掉，返回各个捕获组（0 是整个匹配）。
    private func take(_ pattern: String, from s: inout String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        s = ns.replacingCharacters(in: m.range, with: " ")
        return groups
    }

    /// 英文单词边界（中文前后不需要空格）。
    private static func word(_ alternatives: String) -> String {
        "(?<![a-z0-9])(?:\(alternatives))(?![a-z0-9])"
    }

    static func number(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        if s == "十" { return 10 }
        if let i = s.firstIndex(of: "十") {
            let head = s[s.startIndex..<i]
            let tail = s[s.index(after: i)...]
            let tens = head.isEmpty ? 1 : (head.first.flatMap { digits[$0] } ?? 1)
            let ones = tail.isEmpty ? 0 : (tail.first.flatMap { digits[$0] } ?? 0)
            return tens * 10 + ones
        }
        if s.count == 1, let c = s.first, let d = digits[c] { return d }
        return nil
    }

    // MARK: - 拍摄设备

    private func parseDevice(_ s: inout String, into q: inout SearchQuery) {
        let devices: [(String, String)] = [
            ("iphone", "iPhone"), ("ipad", "iPad"), ("canon|佳能", "Canon"), ("sony|索尼", "Sony"),
            ("nikon|尼康", "Nikon"), ("fujifilm|fuji|富士", "Fujifilm"), ("dji|大疆", "DJI"), ("gopro", "GoPro"),
        ]
        for (alias, name) in devices {
            let a = "(?<![a-z0-9])(?:\(alias))(?![a-z0-9])"
            let patterns = [
                "(?:用|从|来自)?\\s*" + a + "\\s*(?:手机|相机)?\\s*(?:上)?\\s*(?:拍的|拍摄的|拍下的|录的|拍)",
                "(?:taken|shot|recorded)?\\s*(?:on|with|from)\\s+(?:my\\s+|an?\\s+)?" + a,
            ]
            for p in patterns {
                if take(p, from: &s) != nil {
                    q.device = name
                    return
                }
            }
        }
    }

    // MARK: - 来源

    /// 已知来源的别名（“gmail”“微信”“b站”），长的在前，避免“qq邮箱”被“qq”抢先匹配。
    private static let aliasPattern: String = {
        let aliases = SourceCatalog.known.flatMap { $0.aliases }
        let sorted = aliases.sorted { $0.count > $1.count }
        return "(" + sorted.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")"
    }()

    private static func sourceName(alias: String) -> String? {
        let a = alias.lowercased()
        return SourceCatalog.known.first { $0.aliases.contains(a) }?.name
    }

    private func parseSource(_ s: inout String, into q: inout SearchQuery) {
        let alias = Self.aliasPattern
        let aliasPatterns = [
            "(?:来自|从)\\s*\(alias)(?![a-z0-9.])\\s*(?:网站|网盘)?\\s*(?:上|里)?\\s*(?:下载的|下载|收到的|保存的|的)?",
            "(?<![a-z0-9])\(alias)(?![a-z0-9.])\\s*(?:上|里)?\\s*(?:下载的|收到的|保存的|发来的)",
            "(?:downloaded\\s+|saved\\s+)?from\\s+(?:my\\s+)?(?<![a-z0-9])\(alias)(?![a-z0-9.])",
        ]
        for p in aliasPatterns {
            if let g = take(p, from: &s), g.count > 1, let name = Self.sourceName(alias: g[1]) {
                q.source = name
                return
            }
        }
        let host = "([a-z0-9][a-z0-9\\-]*(?:\\.[a-z0-9\\-]+)*)"
        let patterns = [
            "(?:来自|从)\\s*\(host)\\s*(?:网站)?\\s*(?:上)?\\s*(?:下载的|下载)?",
            "(?:downloaded\\s+)?from\\s+(?!(?:last|this|past|today|yesterday)(?![a-z0-9]))\(host)",
        ]
        for p in patterns {
            if let g = take(p, from: &s), g.count > 1, !g[1].isEmpty {
                q.source = g[1]
                return
            }
        }
        if take("(?:下载的|已下载的?|下载来的|" + Self.word("downloaded|downloads") + ")", from: &s) != nil {
            q.downloadedOnly = true
        }
    }

    // MARK: - 大小

    private static let num = "(\\d+(?:\\.\\d+)?)(?![\\d.])"
    private static let notTime = "(?!\\s*(?:days?|weeks?|months?|years?|hours?|天|日|周|星期|个月|月|年|小时))"
    private static let unit = "\\s*(tb|gb|mb|kb|g|m|k|b|兆|字节)?(?![a-z])"

    private func bytes(_ value: String, _ unit: String) -> Int64? {
        guard let v = Double(value) else { return nil }
        let multiplier: Double
        switch unit.lowercased() {
        case "b", "字节": multiplier = 1
        case "k", "kb": multiplier = 1_000
        case "g", "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        default: multiplier = 1_000_000 // m、mb、兆，或没写单位时按 MB
        }
        return Int64(v * multiplier)
    }

    private func parseSize(_ s: inout String, into q: inout SearchQuery) {
        let n = Self.num + Self.notTime + Self.unit
        let minPatterns = [
            "(?:超过|大于|多于|高于|不小于|至少|>=|>|＞|over|above|larger than|bigger than|greater than|more than|at least)\\s*" + n,
            n + "\\s*(?:以上|及以上|或更大|\\+)",
        ]
        let maxPatterns = [
            "(?:小于|低于|少于|不到|不超过|<=|<|＜|under|below|smaller than|less than|at most)\\s*" + n,
            n + "\\s*(?:以下|以内|之内)",
        ]
        for p in minPatterns {
            if let g = take(p, from: &s), g.count > 2, let b = bytes(g[1], g[2]) {
                q.minSize = b
                break
            }
        }
        for p in maxPatterns {
            if let g = take(p, from: &s), g.count > 2, let b = bytes(g[1], g[2]) {
                q.maxSize = b
                break
            }
        }
        if q.minSize == nil,
           take("(?:大文件|" + Self.word("large files?|big files?|huge files?|large|big|huge") + ")", from: &s) != nil {
            q.minSize = 100_000_000
        }
    }

    // MARK: - 日期

    private func component(_ unit: String) -> (Calendar.Component, Int, String) {
        switch unit {
        case "周", "星期", "week", "weeks": return (.day, 7, "周")
        case "个月", "月", "month", "months": return (.month, 1, "个月")
        case "年", "year", "years": return (.year, 1, "年")
        default: return (.day, 1, "天")
        }
    }

    private func ago(_ n: Int, _ unit: String) -> (Date, String) {
        let (comp, factor, label) = component(unit)
        let date = calendar.date(byAdding: comp, value: -n * factor, to: now) ?? now
        let text: String
        switch label {
        case "周": text = String(localized: "\(n) 周")
        case "个月": text = String(localized: "\(n) 个月")
        case "年": text = String(localized: "\(n) 年")
        default: text = String(localized: "\(n) 天")
        }
        return (date, text)
    }

    private func interval(_ comp: Calendar.Component, offset: Int) -> (Date, Date)? {
        let base: Date
        switch comp {
        case .day: base = calendar.date(byAdding: .day, value: offset, to: now) ?? now
        case .weekOfYear: base = calendar.date(byAdding: .day, value: 7 * offset, to: now) ?? now
        case .month: base = calendar.date(byAdding: .month, value: offset, to: now) ?? now
        default: base = calendar.date(byAdding: .year, value: offset, to: now) ?? now
        }
        guard let i = calendar.dateInterval(of: comp, for: base) else { return nil }
        return (i.start, i.end)
    }

    private func parseDate(_ s: inout String, into q: inout SearchQuery) {
        let cn = "(\\d+|[一二两三四五六七八九十]+)"
        let cnUnit = "(天|日|周|星期|个月|月|年)"
        let enUnit = "(days?|weeks?|months?|years?)"
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now

        // 相对：最近 N 天 / N 天内 / last N days
        let recent = [
            "(?:最近|过去|近)\\s*" + cn + "\\s*" + cnUnit,
            cn + "\\s*" + cnUnit + "\\s*(?:内|以内|之内)",
            "(?:last|past|in the last|in the past)\\s+(\\d+)\\s+" + enUnit,
        ]
        for p in recent {
            if let g = take(p, from: &s), g.count > 2, let n = Self.number(g[1]) {
                let (start, label) = ago(n, g[2])
                q.date = DateRange(start: calendar.startOfDay(for: start), end: tomorrow, label: String(localized: "最近 \(label)"))
                return
            }
        }

        // 半年
        let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: now) ?? now
        if take("(?:最近|过去|近)\\s*半年|半年\\s*(?:内|以内|之内)|" + Self.word("(?:in the )?(?:last|past) (?:half a year|six months)"), from: &s) != nil {
            q.date = DateRange(start: calendar.startOfDay(for: sixMonthsAgo), end: tomorrow, label: String(localized: "最近半年"))
            return
        }
        if take("(?:超过|多于)?\\s*半年\\s*(?:前|以前|之前)|超过半年|" + Self.word("older than (?:half a year|six months)|(?:half a year|six months) ago"), from: &s) != nil {
            q.date = DateRange(start: .distantPast, end: sixMonthsAgo, label: String(localized: "半年以前"))
            return
        }

        // 相对：N 天前 / 超过 N 天 / older than N days
        let older = [
            "(?:超过|多于|大于)\\s*" + cn + "\\s*" + cnUnit + "(?:前|以前|之前)?",
            cn + "\\s*" + cnUnit + "\\s*(?:前|以前|之前)",
            "(?:older than|more than|over)\\s+(\\d+)\\s+" + enUnit + "(?:\\s+ago)?",
            "(\\d+)\\s+" + enUnit + "\\s+ago",
        ]
        for p in older {
            if let g = take(p, from: &s), g.count > 2, let n = Self.number(g[1]) {
                let (end, label) = ago(n, g[2])
                q.date = DateRange(start: .distantPast, end: end, label: String(localized: "\(label)以前"))
                return
            }
        }

        // 固定说法
        let named: [(String, Calendar.Component, Int, String)] = [
            ("前天", .day, -2, String(localized: "前天")),
            ("今天|" + Self.word("today"), .day, 0, String(localized: "今天")),
            ("昨天|" + Self.word("yesterday"), .day, -1, String(localized: "昨天")),
            ("本周|这周|这个星期|这星期|这礼拜|" + Self.word("this week"), .weekOfYear, 0, String(localized: "本周")),
            ("上周|上个星期|上星期|上礼拜|上个礼拜|" + Self.word("last week"), .weekOfYear, -1, String(localized: "上周")),
            ("本月|这个月|" + Self.word("this month"), .month, 0, String(localized: "本月")),
            ("上个月|上月|" + Self.word("last month"), .month, -1, String(localized: "上个月")),
            ("今年|" + Self.word("this year"), .year, 0, String(localized: "今年")),
            ("去年|" + Self.word("last year"), .year, -1, String(localized: "去年")),
        ]
        for (pattern, comp, offset, label) in named {
            if take(pattern, from: &s) != nil, let range = interval(comp, offset: offset) {
                q.date = DateRange(start: range.0, end: range.1, label: label)
                return
            }
        }

        // 某个月份：8 月、八月份、in august
        var month: Int?
        if let g = take("(?<![\\d一二三四五六七八九十个上下本这])(\\d{1,2}|十[一二]?|[一二三四五六七八九])\\s*月份?(?!\\s*(?:前|以前|之前|内|以内|之内))", from: &s),
           g.count > 1, let m = Self.number(g[1]), (1...12).contains(m) {
            month = m
        } else {
            let names = ["january", "february", "march", "april", "may", "june", "july",
                         "august", "september", "october", "november", "december"]
            let short = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sept?", "oct", "nov", "dec"]
            for index in 0..<12 {
                if take(Self.word("(?:in\\s+)?(?:\(names[index])|\(short[index]))"), from: &s) != nil {
                    month = index + 1
                    break
                }
            }
        }
        if let month {
            var year = calendar.component(.year, from: now)
            if month > calendar.component(.month, from: now) { year -= 1 }
            if let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
               let end = calendar.date(byAdding: .month, value: 1, to: start) {
                q.date = DateRange(start: start, end: end, label: String(localized: "\(month) 月"))
            }
        }
    }

    // MARK: - 类型

    private func parseKinds(_ s: inout String, into q: inout SearchQuery) {
        let w = Self.word
        let table: [(String, KindFilter)] = [
            ("截图|截屏|屏幕快照|" + w("screenshots?|screen shots?|screen captures?"), .screenshot),
            ("安装包|" + w("installers?"), .extensions(["dmg", "pkg"], label: String(localized: "安装包"))),
            (w("pdfs?"), .extensions(["pdf"], label: "PDF")),
            (w("word|docx?"), .extensions(["doc", "docx"], label: "Word")),
            ("表格|" + w("excel|xlsx?|csv|spreadsheets?|numbers"), .extensions(["xls", "xlsx", "csv", "numbers"], label: String(localized: "表格"))),
            ("幻灯片|演示文稿|" + w("ppt|pptx|keynote|slides|presentations?"), .extensions(["ppt", "pptx", "key"], label: String(localized: "演示文稿"))),
            (w("png"), .extensions(["png"], label: "PNG")),
            (w("jpe?g"), .extensions(["jpg", "jpeg"], label: "JPEG")),
            (w("heic"), .extensions(["heic"], label: "HEIC")),
            (w("gif"), .extensions(["gif"], label: "GIF")),
            (w("mp4"), .extensions(["mp4"], label: "MP4")),
            (w("mov"), .extensions(["mov"], label: "MOV")),
            (w("mp3"), .extensions(["mp3"], label: "MP3")),
            (w("zip"), .extensions(["zip"], label: "ZIP")),
            (w("dmg"), .extensions(["dmg"], label: "DMG")),
            (w("txt"), .extensions(["txt"], label: "TXT")),
            (w("markdown|md"), .extensions(["md", "markdown"], label: "Markdown")),
            (w("epub"), .extensions(["epub"], label: "EPUB")),
            ("录屏|视频|影片|电影|" + w("videos?|movies?|clips?|recordings?"), .category(.videos)),
            ("图片|照片|相片|图像|" + w("images?|photos?|pictures?|pics?"), .category(.images)),
            ("音乐|音频|歌曲|" + w("music|audio|songs?"), .category(.music)),
            ("文档|文稿|" + w("documents?|docs"), .category(.documents)),
            ("压缩包|压缩文件|" + w("archives?|compressed"), .category(.archives)),
            ("应用程序|应用|软件|" + w("apps?|applications?"), .category(.apps)),
        ]
        for (pattern, kind) in table {
            var found = false
            while take(pattern, from: &s) != nil { found = true }
            if found, !q.kinds.contains(kind) { q.kinds.append(kind) }
        }
        // “word 文档”“截图图片”：有了更具体的类型，就不再加笼统的“文稿/图片”。
        let hasSpecific = q.kinds.contains { if case .category = $0 { return false } else { return true } }
        if hasSpecific {
            q.kinds.removeAll { $0 == .category(.documents) || $0 == .category(.images) }
        }
    }

    // MARK: - 剩下的关键词

    private func cleanResidue(_ s: String) -> String {
        var t = s
        for phrase in ["帮我找", "帮我", "找一下", "找出", "查找", "搜索", "给我", "所有的", "所有", "全部", "我的", "有哪些", "哪些"] {
            t = t.replacingOccurrences(of: phrase, with: " ")
        }
        let stop: Set<String> = [
            "的", "文件", "里", "中", "在", "和", "或", "找",
            "files", "file", "all", "my", "the", "find", "show", "me", "of", "in", "with",
            "that", "and", "a", "an", "search", "for", "some", "any", "from", "are", "is",
        ]
        let tokens = t.split(whereSeparator: { $0.isWhitespace }).map { token -> String in
            var x = String(token)
            while x.hasPrefix("的") { x.removeFirst() }
            while x.hasSuffix("的") || x.hasSuffix("文件") {
                if x.hasSuffix("的") { x.removeLast() } else { x.removeLast(2) }
            }
            return x
        }
        return tokens.filter { !$0.isEmpty && !stop.contains($0) }.joined(separator: " ")
    }
}
