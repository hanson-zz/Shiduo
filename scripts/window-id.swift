// 打印某个进程（按 PID）最大的那个普通窗口的 CGWindowID，给 screencapture -l 用。
import CoreGraphics
import Foundation

let pid = Int(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
// window-id <pid> --list：把这个进程的所有窗口打印到 stderr，排查截错窗口时用。
if CommandLine.arguments.contains("--list") {
    for info in list where (info[kCGWindowOwnerPID as String] as? Int) == pid {
        FileHandle.standardError.write("  id=\(info[kCGWindowNumber as String] ?? "?") layer=\(info[kCGWindowLayer as String] ?? "?") onscreen=\(info[kCGWindowIsOnscreen as String] ?? "?") name=\(info[kCGWindowName as String] ?? "") \(info[kCGWindowBounds as String] ?? "")\n".data(using: .utf8)!)
    }
}
func width(_ info: [String: Any]) -> CGFloat {
    (info[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0
}
let mine = list.filter { info in
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    let ownerPID = info[kCGWindowOwnerPID as String] as? Int ?? 0
    return (ownerPID == pid || owner == "Shiduo" || owner == "拾掇")
        && (info[kCGWindowLayer as String] as? Int) == 0 && width(info) > 400
}
if let id = mine.max(by: { width($0) < width($1) })?[kCGWindowNumber as String] as? Int {
    print(id)
} else {
    var msg = "no window for pid \(pid); windows:\n"
    for info in list where width(info) > 100 {
        msg += "  \(info[kCGWindowOwnerName as String] ?? "?") pid=\(info[kCGWindowOwnerPID as String] ?? "?") layer=\(info[kCGWindowLayer as String] ?? "?") onscreen=\(info[kCGWindowIsOnscreen as String] ?? "?") \(info[kCGWindowBounds as String] ?? "")\n"
    }
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(1)
}
