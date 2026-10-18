import Combine
import Foundation
import OSLog
import Security

/// 授权相关的系统日志（只记录错误种类，不记录授权码）。
private let licenseLog = Logger(subsystem: "io.github.hansonzz.shiduo", category: "license")

// MARK: - 配置

/// 拾掇 Pro 的授权配置，集中放在这里。
enum LicenseConfig {
    // 付款和授权码由 Creem 处理（可提现到支付宝）。
    // App 不直接调用 Creem（那需要 API 密钥，而代码是公开的），
    // 而是调用 server/license-relay 里的 Cloudflare Worker 中转。

    // TODO: 在 Creem 建好产品后填入产品 ID（prod_xxx）。为空时不检查（中转服务也会检查）。
    static let productID = "prod_632G8EgQJWLL6m9M5JaBXv"

    // TODO: 换成 Creem 产品的结账链接。
    static let buyURL = URL(string: "https://www.creem.io/payment/prod_632G8EgQJWLL6m9M5JaBXv")!

    // TODO: 部署 Worker 后换成真实地址。
    static let apiBase = "https://shiduo-license.tudou-123.workers.dev/v1/licenses/"

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
        /// 见过的最晚时间（防止把系统时间往回调来重置试用、跳过校验）。
        case maxSeen
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
    /// HTTP 状态码（解析 JSON 时不知道，post 里补上）。
    var httpStatus: Int?
    /// 新版中转对「Creem 暂时不可用 / 限流 / 网络错误」会带 transient: true，而且不带 valid 字段。
    var transient: Bool?
    /// 响应头里的 Date：服务器时间，比本机时钟可信。
    var serverDate: Date?

    /// 授权码属于本应用（配置为空时不检查）。
    var matchesConfig: Bool {
        if !LicenseConfig.productID.isEmpty, productID != LicenseConfig.productID { return false }
        return true
    }
}

/// 服务器的回答属于哪一种。
enum LicenseVerdict: Equatable {
    /// 授权可用。
    case valid
    /// 服务器明确说不可用（找不到、过期、停用、被解绑、不是本产品）：只有这时才解绑本机。
    case invalid
    /// 暂时说不准（Creem 出故障、限流、网络错误、看不懂的回答）：保持现状，稍后重试。
    case transient
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
        let http: HTTPURLResponse?
        do {
            let result = try await URLSession.shared.data(for: request)
            data = result.0
            http = result.1 as? HTTPURLResponse
        } catch {
            let ns = error as NSError
            licenseLog.error("License request \(endpoint, privacy: .public) failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            throw LicenseAPIError.network
        }
        // 授权码无效时中转服务返回 4xx，但正文仍是 JSON，所以不看状态码，直接解析。
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            licenseLog.error("License request \(endpoint, privacy: .public): response is not JSON")
            throw LicenseAPIError.badResponse
        }
        var response = parse(object)
        response.httpStatus = http?.statusCode
        response.serverDate = (http?.value(forHTTPHeaderField: "Date")).flatMap(parseHTTPDate)
        return response
    }

    /// 「Sun, 18 Oct 2026 14:36:00 GMT」。
    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    /// 判断校验（或激活）的回答。flag 是 valid（校验）或 activated（激活）。
    /// 兼容旧版中转：旧版对 Creem 5xx 也回 { valid: false, error: "license error" }，429 回 "too many requests"，
    /// 这些都不算「明确不可用」。
    static func verdict(for r: LicenseResponse, flag: Bool?) -> LicenseVerdict {
        if r.transient == true { return .transient }
        let status = r.status?.lowercased()
        let usable = status == nil || status == "active" || status == "inactive"
        if flag == true {
            return r.matchesConfig && usable ? .valid : .invalid
        }
        if status == "expired" || status == "disabled" || status == "revoked" { return .invalid }
        let text = (r.error ?? "").lowercased()
        let definitive = ["not found", "expired", "disabled", "revoked", "deactivated", "activation limit"]
        if definitive.contains(where: { text.contains($0) }) { return .invalid }
        return .transient
    }

    static func parse(_ object: [String: Any]) -> LicenseResponse {
        var r = LicenseResponse()
        r.transient = object["transient"] as? Bool
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

/// 根据钥匙串里的时间算授权状态（纯逻辑，单元测试覆盖）。
/// 防时钟篡改：
/// - maxSeen 记着见过的最晚时间。本机时间比它早一天以上，说明时钟被往回调了：试用按已结束算，
///   已激活的也不给离线宽限，必须联网校验（校验成功时用服务器时间纠正 maxSeen）。
/// - 上次校验时间在「未来」（比现在晚一天以上）也视为时钟异常，要立刻联网校验。
/// - 同一次运行里刚刚联网校验成功的，用开机以来的单调时间判断，不受系统时间影响。
enum LicenseEvaluator {
    static let tolerance: TimeInterval = 86_400

    struct Input {
        var activated: Bool
        var lastValidated: Date?
        var trialStart: Date?
        var maxSeen: Date?
        var now: Date
        /// 这次运行里上次联网校验成功距今多少秒（单调时钟）；没校验成功过为 nil。
        var sessionValidatedAgo: TimeInterval?
    }

    struct Output: Equatable {
        var state: LicenseState
        /// 已激活，但需要联网校验才能继续用 Pro（离线超过宽限期，或者时钟异常）。
        var needsOnlineCheck: Bool
    }

    static func clockRolledBack(now: Date, maxSeen: Date?) -> Bool {
        guard let maxSeen else { return false }
        return now < maxSeen.addingTimeInterval(-tolerance)
    }

    static func evaluate(_ input: Input) -> Output {
        let now = input.now
        let effectiveNow = max(now, input.maxSeen ?? now)
        let rolledBack = clockRolledBack(now: now, maxSeen: input.maxSeen)
        let grace = TimeInterval(LicenseConfig.offlineGraceDays) * 86_400
        var needsCheck = false
        if input.activated {
            if let ago = input.sessionValidatedAgo, ago >= 0, ago < grace {
                return Output(state: .pro, needsOnlineCheck: false)
            }
            if let last = input.lastValidated, !rolledBack,
               last <= effectiveNow.addingTimeInterval(tolerance),
               effectiveNow.timeIntervalSince(last) < grace {
                return Output(state: .pro, needsOnlineCheck: false)
            }
            needsCheck = true
        }
        guard let start = input.trialStart else {
            return Output(state: .free, needsOnlineCheck: needsCheck)
        }
        // 时钟被往回调过，或者试用开始时间在「未来」：不能再算试用。
        if rolledBack || start > now.addingTimeInterval(tolerance) {
            return Output(state: .expiredTrial, needsOnlineCheck: needsCheck)
        }
        let used = max(0, Int(effectiveNow.timeIntervalSince(start) / 86_400))
        let left = LicenseConfig.trialDays - used
        return Output(state: left > 0 ? .trial(daysLeft: min(left, LicenseConfig.trialDays)) : .expiredTrial,
                      needsOnlineCheck: needsCheck)
    }

    /// 要不要联网校验：没校验过、时钟异常（往回调或上次校验在未来），或者距上次超过间隔。
    static func shouldRevalidate(lastValidated: Date?, now: Date, maxSeen: Date?,
                                 interval: TimeInterval = LicenseConfig.revalidateInterval) -> Bool {
        guard let last = lastValidated else { return true }
        if clockRolledBack(now: now, maxSeen: maxSeen) { return true }
        if last > now.addingTimeInterval(tolerance) { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// 暂时性失败后的重试间隔：1、2、4、8… 分钟，最多 1 小时。
    static func retryDelay(attempt: Int) -> TimeInterval {
        let n = max(1, attempt)
        return min(60 * pow(2, Double(min(n - 1, 10))), 3600)
    }
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
    /// 已激活，但需要联网校验才能继续用 Pro。
    @Published private(set) var needsOnlineCheck = false

    /// 这次运行里上次联网校验成功的单调时间（ProcessInfo.systemUptime）。
    private var validatedUptime: TimeInterval?
    /// 连续暂时性失败的次数，用来退避重试。
    private var transientFailures = 0
    private var retryTask: Task<Void, Never>?

    /// 试用结束的时间；没开始试用时为 nil。
    var trialEndDate: Date? {
        LicenseKeychain.date(.trialStart).map { $0.addingTimeInterval(TimeInterval(LicenseConfig.trialDays) * 86_400) }
    }

    /// 还没开始过试用，也没有激活。
    var canStartTrial: Bool {
        state == .free
    }

    var statusText: String {
        switch state {
        case .free: return needsOnlineCheck ? String(localized: "需要联网校验授权") : String(localized: "免费版")
        case .trial(let days): return String(localized: "Pro 试用中，还剩 \(days) 天")
        case .pro: return String(localized: "拾掇 Pro 已激活")
        case .expiredTrial:
            return needsOnlineCheck ? String(localized: "需要联网校验授权") : String(localized: "试用已结束")
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
        var maxSeen = LicenseKeychain.date(.maxSeen)
        // 记下见过的最晚时间（最多每小时写一次钥匙串）。
        if maxSeen == nil || now > maxSeen!.addingTimeInterval(3600) {
            LicenseKeychain.setDate(now, for: .maxSeen)
            maxSeen = now
        }
        let output = LicenseEvaluator.evaluate(.init(
            activated: isActivated,
            lastValidated: lastValidated,
            trialStart: LicenseKeychain.date(.trialStart),
            maxSeen: maxSeen,
            now: now,
            sessionValidatedAgo: validatedUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
        ))
        if needsOnlineCheck != output.needsOnlineCheck { needsOnlineCheck = output.needsOnlineCheck }
        if state != output.state { state = output.state }
    }

    /// 第一次打开 Pro 功能或点「开始试用」时开始 7 天试用。开始过就不会再重置。
    func startTrialIfNeeded() {
        guard state == .free, LicenseKeychain.get(.trialStart) == nil else { return }
        LicenseKeychain.setDate(Date(), for: .trialStart)
        refreshState()
    }

    /// 启动时调用：距离上次成功校验超过 24 小时才联网；离线时保持 30 天。
    /// force 为 true 时不看间隔（「立即校验」、网络恢复、退避重试）。
    /// 只有服务器明确说不可用时才解绑；Creem 故障、限流、网络错误都保持现状并退避重试。
    func revalidateIfNeeded(force: Bool = false) async {
        defer { refreshState() }
        guard let key = LicenseKeychain.get(.licenseKey),
              let instance = LicenseKeychain.get(.instanceID) else { return }
        if !force, !LicenseEvaluator.shouldRevalidate(lastValidated: LicenseKeychain.date(.lastValidated), now: Date(),
                                                        maxSeen: LicenseKeychain.date(.maxSeen)) {
            return
        }
        if force { isWorking = true }
        defer { if force { isWorking = false } }
        let response: LicenseResponse
        do {
            response = try await LicenseAPI.validate(key: key, instanceID: instance)
        } catch {
            // 没联网或服务器出错：保持现状，宽限期内仍是 Pro。
            scheduleRetry()
            return
        }
        switch LicenseAPI.verdict(for: response, flag: response.valid) {
        case .valid:
            markValidated(serverDate: response.serverDate)
        case .invalid:
            // 服务器明确说不可用（已停用、已过期、在后台被解绑……）。
            cancelRetry()
            LicenseKeychain.set(nil, for: .instanceID)
            LicenseKeychain.set(nil, for: .lastValidated)
            validatedUptime = nil
            errorMessage = Self.message(for: response.error, status: response.status)
            licenseLog.error("License revalidation rejected, status: \(response.status ?? "-", privacy: .public)")
        case .transient:
            licenseLog.error("License revalidation: server temporarily unavailable (\(response.httpStatus ?? 0, privacy: .public))")
            scheduleRetry()
        }
    }

    /// 「立即校验」按钮、网络恢复时调用。
    func verifyNow() async {
        errorMessage = nil
        await revalidateIfNeeded(force: true)
        if needsOnlineCheck, errorMessage == nil, isActivated {
            errorMessage = String(localized: "暂时连不上授权服务器，稍后会自动重试。")
        }
    }

    /// 有待重试的校验（暂时性失败过）。
    var hasPendingRetry: Bool { retryTask != nil }

    private func markValidated(serverDate: Date?) {
        cancelRetry()
        let trusted = serverDate ?? Date()
        LicenseKeychain.setDate(trusted, for: .lastValidated)
        // 服务器时间可信：用它纠正「见过的最晚时间」（时钟曾被调到未来又调回来的情况）。
        if let serverDate { LicenseKeychain.setDate(serverDate, for: .maxSeen) }
        validatedUptime = ProcessInfo.processInfo.systemUptime
        errorMessage = nil
    }

    private func scheduleRetry() {
        transientFailures += 1
        let delay = LicenseEvaluator.retryDelay(attempt: transientFailures)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            await self?.revalidateIfNeeded(force: true)
        }
    }

    private func cancelRetry() {
        transientFailures = 0
        retryTask?.cancel()
        retryTask = nil
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
                errorMessage = LicenseAPI.verdict(for: response, flag: response.activated) == .transient
                    ? String(localized: "授权服务器暂时不可用，请稍后再试。")
                    : Self.message(for: response.error, status: response.status)
                licenseLog.error("Activation failed: \(response.error ?? "-", privacy: .public)")
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
            markValidated(serverDate: response.serverDate)
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
            } else if LicenseAPI.verdict(for: response, flag: response.deactivated) == .transient {
                errorMessage = String(localized: "授权服务器暂时不可用，请稍后再试。")
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
        validatedUptime = nil
        cancelRetry()
        refreshState()
    }

    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(4)) + "••••••••" + String(key.suffix(4))
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
