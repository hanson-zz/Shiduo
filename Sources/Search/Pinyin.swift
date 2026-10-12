import Foundation

/// 拼音 / 首字母匹配：输入 “nianbao”、“nb”、“nianb” 都能找到「年报.pdf」。
enum Pinyin {
    /// 是不是一个可能是拼音的关键词：2 个以上字母，没有别的字符。
    static func looksLikePinyin(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.count >= 2, t.count <= 40 else { return false }
        return t.allSatisfy { $0 >= "a" && $0 <= "z" }
    }

    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHan)
    }

    static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF: return true
        default: return false
        }
    }

    private static let cache = NSCache<NSString, NSArray>()
    private static let lock = NSLock()
    private static var charCache: [Character: String] = [:]

    /// 一个汉字的拼音（不带声调，小写）。
    static func syllable(of ch: Character) -> String {
        lock.lock()
        if let hit = charCache[ch] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let s = NSMutableString(string: String(ch))
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
        let result = (s as String).lowercased().filter { $0 >= "a" && $0 <= "z" }
        lock.lock()
        charCache[ch] = result
        lock.unlock()
        return result
    }

    /// 把文件名拆成“音节”：汉字是它的拼音，字母数字按连续的一段算一个。
    static func syllables(_ name: String) -> [String] {
        if let hit = cache.object(forKey: name as NSString) as? [String] { return hit }
        var result: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { result.append(word) }
            word = ""
        }
        for ch in name {
            if ch.unicodeScalars.contains(where: isHan) {
                flush()
                let py = syllable(of: ch)
                if !py.isEmpty { result.append(py) }
            } else if ch.isLetter || ch.isNumber {
                word.append(contentsOf: ch.lowercased())
            } else {
                flush()
            }
        }
        flush()
        cache.setObject(result as NSArray, forKey: name as NSString)
        return result
    }

    /// 关键词能不能用连续几个音节拼出来，每个音节可以只取开头几个字母。
    /// 例如「年度报告」：nianbao、ndbg、niandubaogao、ndbaog 都算。
    static func matches(_ name: String, query: String) -> Bool {
        let q = Array(query.lowercased())
        guard !q.isEmpty, containsHan(name) else { return false }
        let syl = syllables(name).map(Array.init)
        guard !syl.isEmpty else { return false }
        // memo[i][j]：从第 i 个音节、关键词第 j 个字母开始能否匹配完。
        var memo: [[Bool?]] = Array(repeating: Array(repeating: nil, count: q.count + 1), count: syl.count + 1)
        func go(_ i: Int, _ j: Int) -> Bool {
            if j == q.count { return true }
            if i == syl.count { return false }
            if let m = memo[i][j] { return m }
            let s = syl[i]
            var k = 0
            var ok = false
            while k < s.count, j + k < q.count, s[k] == q[j + k] {
                k += 1
                if go(i + 1, j + k) { ok = true; break }
            }
            // 关键词在这个音节中间结束（例如 “nian” 打到一半 “nia”）。
            if !ok && j + k == q.count && k > 0 { ok = true }
            memo[i][j] = ok
            return ok
        }
        for start in 0..<syl.count where go(start, 0) { return true }
        return false
    }
}
