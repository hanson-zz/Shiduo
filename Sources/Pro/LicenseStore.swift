import Foundation
import IOKit
import OSLog
import Security

private let storeLog = Logger(subsystem: "io.github.hansonzz.shiduo", category: "license-store")

// MARK: - 授权信息的存放

/// 授权信息存在 ~/Library/Application Support/Shiduo/license.json（只有自己能读写，0600），
/// 带本机专属的签名，手改会被发现。试用开始时间和「激活过」另在 UserDefaults 里备份一份，
/// 只删文件不能重置试用。
///
/// 以前存在登录钥匙串里，但自签名 App 每次更新都会被钥匙串当成新 App 而弹窗要密码，
/// 所以新版本第一次启动时把旧钥匙串里的内容搬过来（可能最后弹一次），之后再也不碰钥匙串。
/// 用法和以前的 LicenseKeychain 一样：get / set / date / setDate。
enum LicenseStore {
    enum Account: String, CaseIterable {
        case licenseKey
        case instanceID
        case lastValidated
        case trialStart
        /// 见过的最晚时间（防止把系统时间往回调来重置试用、跳过校验）。
        case maxSeen
        /// 这台 Mac 激活过授权码（解绑 / 授权码失效后不再说「试用已结束」，也不能再开始试用）。
        case everActivated
    }

    /// 以前钥匙串里的 service 名（只在迁移时用）。
    static let legacyKeychainService = "io.github.hansonzz.shiduo.license"
    static let migratedFlagKey = "license.migratedFromKeychain"
    static let backupTrialStartKey = "license.backup.trialStart"
    static let backupEverActivatedKey = "license.backup.everActivated"

    private static let lock = NSLock()
    /// 这次运行里读到的值（只从磁盘读一次）。
    private static var cache: [String: String]?
    private static var defaults: UserDefaults { .standard }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Shiduo", isDirectory: true).appendingPathComponent("license.json")
    }

    private static let signingKey = LicenseStoreLogic.deriveKey(hardwareUUID: hardwareUUID())

    // MARK: 读写（和以前的 LicenseKeychain 一样）

    static func get(_ account: Account) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()[account.rawValue]
    }

    static func set(_ value: String?, for account: Account) {
        lock.lock(); defer { lock.unlock() }
        var values = loadLocked()
        guard values[account.rawValue] != value else { return }
        values[account.rawValue] = value
        cache = values
        mirrorBackups(values)
        write(values)
    }

    static func date(_ account: Account) -> Date? {
        LicenseStoreLogic.date(from: get(account))
    }

    static func setDate(_ date: Date?, for account: Account) {
        set(date.map(LicenseStoreLogic.text(from:)), for: account)
    }

    // MARK: 载入

    private static func loadLocked() -> [String: String] {
        if let cache { return cache }

        var fileValues: [String: String] = [:]
        var tampered = false
        if let data = try? Data(contentsOf: fileURL) {
            switch LicenseStoreLogic.decode(data, key: signingKey) {
            case .valid(let values): fileValues = values
            case .tampered:
                tampered = true
                storeLog.error("license.json failed verification; treating as missing")
            }
        }

        let onDisk = fileValues
        // 一次性迁移：文件里还没东西时，从旧钥匙串读一次（最多读两项，见 migrationOrder）。
        var keychainCleanup = false
        if !defaults.bool(forKey: migratedFlagKey) {
            if fileValues.isEmpty {
                let result = readLegacyKeychain()
                if !result.values.isEmpty {
                    fileValues = result.values
                    tampered = false
                }
                keychainCleanup = result.complete && !result.values.isEmpty
            }
            // 读失败 / 被拒也标记成已迁移：不再反复弹窗，付费用户可以重新输入授权码。
            defaults.set(true, forKey: migratedFlagKey)
        }

        let backupStart = defaults.object(forKey: backupTrialStartKey) as? Double
        let resolved = LicenseStoreLogic.resolve(
            fileValues: fileValues, tampered: tampered,
            backupTrialStart: backupStart.map { Date(timeIntervalSince1970: $0) },
            backupEverActivated: defaults.bool(forKey: backupEverActivatedKey))

        cache = resolved
        mirrorBackups(resolved)
        if resolved != onDisk || tampered {
            // 没写成功就先不删旧钥匙串里的内容。
            if !write(resolved) { keychainCleanup = false }
        }
        if keychainCleanup { deleteLegacyKeychainItems() }
        return resolved
    }

    /// 试用开始时间只往早了记，「激活过」只记不删。
    private static func mirrorBackups(_ values: [String: String]) {
        if let start = LicenseStoreLogic.date(from: values[LicenseStoreLogic.trialStartKey]) {
            let old = (defaults.object(forKey: backupTrialStartKey) as? Double).map { Date(timeIntervalSince1970: $0) }
            if let merged = LicenseStoreLogic.mergeTrialStart(file: start, backup: old), merged != old {
                defaults.set(merged.timeIntervalSince1970, forKey: backupTrialStartKey)
            }
        }
        if values[LicenseStoreLogic.everActivatedKey] != nil, !defaults.bool(forKey: backupEverActivatedKey) {
            defaults.set(true, forKey: backupEverActivatedKey)
        }
    }

    /// 原子写入：先写同目录下的临时文件（0600），再改名覆盖。
    @discardableResult
    private static func write(_ values: [String: String]) -> Bool {
        let url = fileURL
        let fm = FileManager.default
        guard let data = LicenseStoreLogic.encode(values, key: signingKey) else { return false }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".license.\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: temp.path, contents: data,
                                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
                storeLog.error("Could not create temporary license file")
                return false
            }
            if rename(temp.path, url.path) != 0 {
                try? fm.removeItem(at: temp)
                storeLog.error("Could not move license file into place (errno \(errno, privacy: .public))")
                return false
            }
            return true
        } catch {
            storeLog.error("Could not write license file: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: 硬件 UUID

    static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "unknown" }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return (property?.takeRetainedValue() as? String) ?? "unknown"
    }

    // MARK: 旧钥匙串（只在迁移时碰一次）

    private struct LegacyRead {
        var values: [String: String] = [:]
        /// 要读的项都读到了（没有被拒、没有出错）。
        var complete = true
    }

    private static var legacyReadDone = false

    private static func readLegacyKeychain() -> LegacyRead {
        // 每次运行最多一次，不管有几项。
        guard !legacyReadDone else { return LegacyRead(complete: false) }
        legacyReadDone = true

        // 先只查有哪些项（只看属性，不会弹窗）。
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        guard listStatus == errSecSuccess, let items = listResult as? [[String: Any]] else {
            if listStatus != errSecItemNotFound {
                storeLog.error("Legacy keychain listing failed: \(listStatus, privacy: .public)")
            }
            return LegacyRead(complete: listStatus == errSecItemNotFound)
        }
        let present = Set(items.compactMap { $0[kSecAttrAccount as String] as? String })

        var read = LegacyRead()
        for account in LicenseStoreLogic.migrationOrder(present: present) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyKeychainService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) {
                read.values[account] = text
            } else if status == errSecItemNotFound {
                continue
            } else {
                // 被拒、取消或出错：不再读别的项，免得再弹。
                storeLog.error("Legacy keychain read stopped: \(status, privacy: .public)")
                read.complete = false
                break
            }
        }
        // 有授权码就说明激活过（和 LicenseManager.refreshState 的规则一致）。
        if read.values[LicenseStoreLogic.licenseKeyKey] != nil {
            read.values[LicenseStoreLogic.everActivatedKey] = "1"
        }
        return read
    }

    /// 搬完后删掉旧钥匙串里拾掇的所有项（一次调用）。
    private static func deleteLegacyKeychainItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            storeLog.error("Could not delete legacy keychain items: \(status, privacy: .public)")
        }
    }
}
