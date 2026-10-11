// 打印某个应用最上面那个窗口的 CGWindowID，给 screencapture -l 用。
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Shiduo"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = list.first { info in
    (info[kCGWindowOwnerName as String] as? String) == owner
        && (info[kCGWindowLayer as String] as? Int) == 0
        && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) > 400
}
if let id = match?[kCGWindowNumber as String] as? Int {
    print(id)
} else {
    FileHandle.standardError.write("no window for \(owner)\n".data(using: .utf8)!)
    exit(1)
}
