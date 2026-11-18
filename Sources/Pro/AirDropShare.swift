import AppKit

// MARK: - 隔空投送

enum AirDropShare {
    /// 系统分享服务要一直持有，否则窗口一闪就没了。
    @MainActor private static var service: NSSharingService?
    @MainActor private static var delegate: AirDropShareDelegate?

    @MainActor static var isAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    /// 用隔空投送发送文件。completion：true 表示发出去了，false 表示取消或失败（没法发也是 false）。
    @MainActor static func send(_ urls: [URL], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !urls.isEmpty, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            completion?(false)
            return
        }
        let delegate = AirDropShareDelegate(completion: completion)
        s.delegate = delegate
        service = s
        self.delegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        s.perform(withItems: urls)
    }
}

/// 接系统分享服务的回调：发完或取消时告诉篮筐。
final class AirDropShareDelegate: NSObject, NSSharingServiceDelegate {
    private var completion: (@MainActor (Bool) -> Void)?

    init(completion: (@MainActor (Bool) -> Void)?) {
        self.completion = completion
    }

    private func finish(_ success: Bool) {
        let done = completion
        completion = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated { done?(success) }
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(true)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(false)
    }
}
