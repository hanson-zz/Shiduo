import Combine
import Foundation
import Security

// MARK: - 配置

/// 拾掇 Pro 的授权配置，集中放在这里。
enum LicenseConfig {
    // 付款和授权码由 Creem 处理（可提现到支付宝）。
    // App 不直接调用 Creem（那需要 API 密钥，而代码是公开的），
    // 而是调用 server/license-relay 里的 Cloudflare Worker 中转。

    // TODO: 在 Creem 建好产品后填入产品 ID（prod_xxx）。为空时不检查（中转服务也会检查）。
    static let productID = ""

    // TODO: 换成 Creem 产品的结账链接。
    static let buyURL = URL(string: "https://www.creem.io")!

    // TODO: 部署 Worker 后换成真实地址。
    static let apiBase = "https://shiduo-license.workers.dev/v1/licenses/"

    /// 免费试用天数。
    static let trialDays = 7
    /// 离线时，距离上次成功校验多少天内仍然算 Pro。
    static let offlineGraceDays = 30
    /// 启动时最多每 24 小时联网校验一次。
    static let revalidateInterval: TimeInterval = 86_400
}

// MARK: - 钥匙串

/// 授权信息存在钥匙串里（kSecClassGenericPassword），重装拾掇也不会丢，试用期也不会被重置。
enum LicenseKeychain {
    static let service = "io.github.hansonzz.shiduo.license"

    enum Account: String {
        case licenseKey
        case instanceID
        case lastValidated
        case trialStart
    }

    static func get(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: Account) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "拾掇授权"
        SecItemAdd(item as CFDictionary, nil)
    }

    static func date(_ account: Account) -> Date? {
        guard let text = get(account), let seconds = Double(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func setDate(_ date: Date?, for account: Account) {
        set(date.map { String($0.timeIntervalSince1970) }, for: account)
    }
}

// MARK: - 授权 API（经 Cloudflare Worker 中转到 Creem）

/// 中转服务返回的内容里我们关心的几项。
struct LicenseResponse {
    var activated: Bool?
    var valid: Bool?
    var deactivated: Bool?
    var error: String?
    var instanceID: String?
    var status: String?
    var productID: String?

    /// 授权码属于本应用（配置为空时不检查）。
    var matchesConfig: Bool {
        if !LicenseConfig.productID.isEmpty, productID != LicenseConfig.productID { return false }
        return true
    }
}

enum LicenseAPIError: Error {
    case network
    case badResponse
}

/// 中转服务：server/license-relay/worker.js；上游 https://docs.creem.io/api-reference
enum LicenseAPI {
    static func activate(key: String, instanceName: String) async throws -> LicenseResponse {
        try await post("activate", ["key": key, "instance_name": instanceName])
    }

    static func validate(key: String, instanceID: String) async throws -> LicenseResponse {
        try await post("validate", ["key": key, "instance_id": instanceID])
    }

    static func deactivate(key: String, instanceID: String) async throws -> LicenseResponse {
        try await post("deactivate", ["key": key, "instance_id": instanceID])
    }

    private static func post(_ endpoint: String, _ params: [String: String]) async throws -> LicenseResponse {
        guard let url = URL(string: LicenseConfig.apiBase + endpoint) else { throw LicenseAPIError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        request.timeoutInterval = 15

        let data: Data
        do {
            let result = try await URLSession.shared.data(for: request)
            data = result.0
        } catch {
            throw LicenseAPIError.network
        }
        // 授权码无效时中转服务返回 4xx，但正文仍是 JSON，所以不看状态码，直接解析。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LicenseAPIError.badResponse
        }
        return parse(object)
    }

    static func parse(_ object: [String: Any]) -> LicenseResponse {
        var r = LicenseResponse()
        r.activated = object["activated"] as? Bool
        r.valid = object["valid"] as? Bool
        r.deactivated = object["deactivated"] as? Bool
        r.error = object["error"] as? String
        if let instance = object["instance"] as? [String: Any] {
            r.instanceID = instance["id"] as? String
        }
        if let key = object["license_key"] as? [String: Any] {
            r.status = key["status"] as? String
        }
        if let meta = object["meta"] as? [String: Any] {
            r.productID = meta["product_id"] as? String
        }
        return r
    }
}

// MARK: - 授权状态

enum LicenseState: Equatable {
    case free
    case trial(daysLeft: Int)
    case pro
    case expiredTrial
}

/// 拾掇 Pro 的授权与试用。所有现有功能永远免费，只有 Pro 功能需要它。
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var state: LicenseState = .free
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    /// 打开主窗口里的 Pro 介绍页。
    @Published var showPaywall = false

    var isPro: Bool {
        switch state {
        case .trial, .pro: return true
        case .free, .expiredTrial: return false
        }
    }

    /// 这台 Mac 已经用授权码激活（refreshState 时从钥匙串读出，避免每次刷新界面都读钥匙串）。
    @Published private(set) var isActivated = false
    /// 授权码只显示前 4 位和后 4 位。
    @Published private(set) var maskedKey: String?
    @Published private(set) var lastValidated: Date?

    /// 还没开始过试用，也没有激活。
    var canStartTrial: Bool {
        state == .free
    }

    var statusText: String {
        switch state {
        case .free: return String(localized: "免费版")
        case .trial(let days): return String(localized: "Pro 试用中，还剩 \(days) 天")
        case .pro: return String(localized: "拾掇 Pro 已激活")
        case .expiredTrial: return String(localized: "试用已结束")
        }
    }

    static var instanceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private init() {
        refreshState()
    }

    /// 根据钥匙串里的信息重新计算状态（不联网）。
    func refreshState() {
        let now = Date()
        let key = LicenseKeychain.get(.licenseKey)
        isActivated = key != nil && LicenseKeychain.get(.instanceID) != nil
        maskedKey = key.map(Self.mask)
        lastValidated = LicenseKeychain.date(.lastValidated)
        if isActivated, let last = lastValidated {
            let grace = TimeInterval(LicenseConfig.offlineGraceDays) * 86_400
            if now.timeIntervalSince(last) < grace {
                state = .pro
                return
            }
        }
        guard let start = LicenseKeychain.date(.trialStart) else {
            state = .free
            return
        }
        let used = max(0, Int(now.timeIntervalSince(start) / 86_400))
        let left = LicenseConfig.trialDays - used
        state = left > 0 ? .trial(daysLeft: min(left, LicenseConfig.trialDays)) : .expiredTrial
    }

    /// 第一次打开 Pro 功能或点「开始试用」时开始 7 天试用。开始过就不会再重置。
    func startTrialIfNeeded() {
        guard state == .free, LicenseKeychain.get(.trialStart) == nil else { return }
        LicenseKeychain.setDate(Date(), for: .trialStart)
        refreshState()
    }

    /// 启动时调用：距离上次成功校验超过 24 小时才联网；离线时保持 30 天。
    func revalidateIfNeeded() async {
        defer { refreshState() }
        guard let key = LicenseKeychain.get(.licenseKey),
              let instance = LicenseKeychain.get(.instanceID) else { return }
        if let last = LicenseKeychain.date(.lastValidated), Date().timeIntervalSince(last) < LicenseConfig.revalidateInterval {
            return
        }
        guard let response = try? await LicenseAPI.validate(key: key, instanceID: instance) else {
            // 没联网或服务器出错：保持现状，宽限期内仍是 Pro。
            return
        }
        if response.valid == true, response.matchesConfig, Self.isUsable(response.status) {
            LicenseKeychain.setDate(Date(), for: .lastValidated)
        } else if response.valid != nil || response.status != nil {
            // 服务器明确说不可用（已停用、已过期、在后台被解绑……）。
            LicenseKeychain.set(nil, for: .instanceID)
            LicenseKeychain.set(nil, for: .lastValidated)
            errorMessage = Self.message(for: response.error, status: response.status)
        }
    }

    /// 用授权码激活这台 Mac。成功返回 true。
    @discardableResult
    func activate(_ raw: String) async -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = String(localized: "请输入授权码。")
            return false
        }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await LicenseAPI.activate(key: key, instanceName: Self.instanceName)
            guard response.activated == true, let instance = response.instanceID else {
                errorMessage = Self.message(for: response.error, status: response.status)
                return false
            }
            guard response.matchesConfig else {
                // 不是拾掇的授权码：把刚占用的激活名额还回去。
                _ = try? await LicenseAPI.deactivate(key: key, instanceID: instance)
                errorMessage = String(localized: "这个授权码不属于拾掇 Pro。")
                return false
            }
            LicenseKeychain.set(key, for: .licenseKey)
            LicenseKeychain.set(instance, for: .instanceID)
            LicenseKeychain.setDate(Date(), for: .lastValidated)
            refreshState()
            return true
        } catch {
            errorMessage = String(localized: "无法连接授权服务器，请检查网络后再试。")
            return false
        }
    }

    /// 解绑这台 Mac，把激活名额留给别的 Mac。
    func deactivate() async {
        guard let key = LicenseKeychain.get(.licenseKey) else { return }
        guard let instance = LicenseKeychain.get(.instanceID) else {
            clearActivation(keepKey: false)
            return
        }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await LicenseAPI.deactivate(key: key, instanceID: instance)
            let gone = (response.error ?? "").lowercased().contains("not found")
            if response.deactivated == true || gone {
                clearActivation(keepKey: false)
            } else {
                errorMessage = Self.message(for: response.error, status: response.status)
            }
        } catch {
            errorMessage = String(localized: "无法连接授权服务器，请检查网络后再试。")
        }
    }

    private func clearActivation(keepKey: Bool) {
        if !keepKey { LicenseKeychain.set(nil, for: .licenseKey) }
        LicenseKeychain.set(nil, for: .instanceID)
        LicenseKeychain.set(nil, for: .lastValidated)
        refreshState()
    }

    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
    }

    private static func isUsable(_ status: String?) -> Bool {
        guard let status else { return true }
        return status == "active" || status == "inactive"
    }

    /// 把中转服务的英文错误翻成中文。
    static func message(for error: String?, status: String?) -> String {
        let text = (error ?? "").lowercased()
        if text.contains("activation limit") {
            return String(localized: "这个授权码的激活次数已用完。请先在旧 Mac 的拾掇设置里「解绑此 Mac」，再来激活。")
        }
        if text.contains("not found") || text.contains("invalid") {
            return String(localized: "授权码不正确，请检查是否完整复制。")
        }
        if text.contains("disabled") || status == "disabled" {
            return String(localized: "这个授权码已被停用。")
        }
        if text.contains("expired") || status == "expired" {
            return String(localized: "这个授权码已过期。")
        }
        if text.contains("too many") {
            return String(localized: "请求太频繁，请稍后再试。")
        }
        if let error, !error.isEmpty {
            return String(localized: "授权失败：\(error)")
        }
        return String(localized: "授权失败，请稍后再试。")
    }
}
