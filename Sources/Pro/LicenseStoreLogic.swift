import CryptoKit
import Foundation

/// 授权文件的纯逻辑部分（签名、校验、合并规则、迁移顺序），不碰磁盘和钥匙串，方便单元测试。
///
/// 为什么不再用钥匙串：拾掇是自签名、没有 Apple Team ID 的 App。这类 App 在钥匙串里的访问控制
/// 按每个版本的代码签名（cdhash）认人，每次更新都算「另一个 App」，于是每次都弹
/// 「"拾掇"想要访问你的钥匙串中的密钥"拾掇授权"」，点了「始终允许」下次更新还会弹。
/// 现在改存 ~/Library/Application Support/Shiduo/license.json，用本机硬件 UUID 派生的密钥做 HMAC，
/// 手改文件会被发现。
enum LicenseStoreLogic {
    static let bundleID = "io.github.hanson-zz.shiduo"
    static let formatVersion = 1

    /// 文件里的账户名（和以前钥匙串里的 account 一样）。
    static let trialStartKey = "trialStart"
    static let everActivatedKey = "everActivated"
    static let licenseKeyKey = "licenseKey"
    static let instanceIDKey = "instanceID"

    /// 文件被改过、又不知道试用开始时间时用的「很早以前就开始过」：不给新的试用。
    static let tamperedTrialStart = Date(timeIntervalSince1970: 0)

    // MARK: 签名

    /// 密钥 = SHA256(bundle id | 硬件 UUID | 版本)。换一台 Mac 拷过去的文件也会被当成改过。
    static func deriveKey(bundleID: String = bundleID, hardwareUUID: String) -> SymmetricKey {
        let material = "\(bundleID)|\(hardwareUUID)|shiduo-license-v\(formatVersion)"
        return SymmetricKey(data: Data(SHA256.hash(data: Data(material.utf8))))
    }

    /// 规范化后的待签内容：按键排序，键值之间、条目之间用不会出现在值里的控制字符分隔。
    static func canonicalPayload(_ values: [String: String]) -> Data {
        var text = "v\(formatVersion)"
        for key in values.keys.sorted() {
            text += "\u{1E}" + key + "\u{1F}" + (values[key] ?? "")
        }
        return Data(text.utf8)
    }

    static func signature(_ values: [String: String], key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: canonicalPayload(values), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private struct FileBody: Codable {
        var version: Int
        var values: [String: String]
        var hmac: String
    }

    static func encode(_ values: [String: String], key: SymmetricKey) -> Data? {
        let body = FileBody(version: formatVersion, values: values, hmac: signature(values, key: key))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(body)
    }

    enum Decoded: Equatable {
        case valid([String: String])
        /// 读得出来但签名不对，或者根本不是合法内容：当成改过。
        case tampered
    }

    static func decode(_ data: Data, key: SymmetricKey) -> Decoded {
        guard let body = try? JSONDecoder().decode(FileBody.self, from: data),
              body.version == formatVersion else { return .tampered }
        let expected = Data(signature(body.values, key: key).utf8)
        let given = Data(body.hmac.lowercased().utf8)
        // 固定时间比较。
        guard expected.count == given.count else { return .tampered }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, given) { diff |= a ^ b }
        return diff == 0 ? .valid(body.values) : .tampered
    }

    // MARK: 合并规则

    /// 取最早的试用开始时间：删掉文件或 UserDefaults 其中一个都不能重置试用。
    static func mergeTrialStart(file: Date?, backup: Date?) -> Date? {
        switch (file, backup) {
        case let (f?, b?): return min(f, b)
        case let (f?, nil): return f
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// 任何一处记过「激活过」就算激活过。
    static func mergeEverActivated(file: Bool, backup: Bool) -> Bool { file || backup }

    static func date(from text: String?) -> Date? {
        guard let text, let seconds = Double(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func text(from date: Date) -> String { String(date.timeIntervalSince1970) }

    /// 把文件内容和 UserDefaults 里的备份合在一起，得到真正生效的值。
    /// - tampered: 文件存在但被改过 / 坏了（这时 fileValues 应为空）。
    static func resolve(fileValues: [String: String], tampered: Bool,
                        backupTrialStart: Date?, backupEverActivated: Bool) -> [String: String] {
        var values = fileValues
        let ever = mergeEverActivated(file: values[everActivatedKey] != nil, backup: backupEverActivated)
        if ever { values[everActivatedKey] = "1" }
        var start = mergeTrialStart(file: date(from: values[trialStartKey]), backup: backupTrialStart)
        // 文件被改过，又查不到试用开始时间、也没激活过：保守处理，不给新的试用。
        if tampered, start == nil, !ever { start = tamperedTrialStart }
        if let start { values[trialStartKey] = text(from: start) } else { values[trialStartKey] = nil }
        return values
    }

    // MARK: 从钥匙串迁移

    /// 只读真正需要的项，尽量少弹窗（每读一项钥匙串都可能弹一次）：
    /// - 有授权码：读授权码和实例 ID（激活过就不需要试用信息）。
    /// - 没有授权码：读「激活过」标记；没有这个标记才读试用开始时间。
    /// lastValidated / maxSeen 不读：缺了只会让 App 启动时联网校验一次、重新记时间。
    /// 返回值是「按顺序要读的项」，present 是钥匙串里存在的项（只查属性，不会弹窗）。
    static func migrationOrder(present: Set<String>) -> [String] {
        if present.contains(licenseKeyKey) {
            return [licenseKeyKey, instanceIDKey].filter(present.contains)
        }
        if present.contains(everActivatedKey) { return [everActivatedKey] }
        if present.contains(trialStartKey) { return [trialStartKey] }
        return []
    }
}
