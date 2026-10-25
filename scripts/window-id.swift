// 打印某个进程（按 PID）最大的那个普通窗口的 CGWindowID，给 screencapture -l 用。
//
//     window-id <pid> [--list] [--smallest | --panel] [--bounds]
//
// --smallest：屏幕上最小的那个普通窗口（设置、图片工具、卸载 App 这些工具窗口，主窗口在它后面）。
// --panel：屏幕上层级最高的窗口（刘海暂存架这类浮在菜单栏上的面板）。
// --bounds：打印窗口位置 "x,y,w,h"（给 screencapture -R 截一块区域，连同弹出的气泡一起截）。
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let pid = Int(args.dropFirst().first ?? "") ?? -1
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
// window-id <pid> --list：把这个进程的所有窗口打印到 stderr，排查截错窗口时用。
if args.contains("--list") {
    for info in list where (info[kCGWindowOwnerPID as String] as? Int) == pid {
        FileHandle.standardError.write("  id=\(info[kCGWindowNumber as String] ?? "?") layer=\(info[kCGWindowLayer as String] ?? "?") onscreen=\(info[kCGWindowIsOnscreen as String] ?? "?") name=\(info[kCGWindowName as String] ?? "") \(info[kCGWindowBounds as String] ?? "")\n".data(using: .utf8)!)
    }
}
func bounds(_ info: [String: Any]) -> [String: CGFloat] {
    info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
}
func width(_ info: [String: Any]) -> CGFloat { bounds(info)["Width"] ?? 0 }
func height(_ info: [String: Any]) -> CGFloat { bounds(info)["Height"] ?? 0 }
func layer(_ info: [String: Any]) -> Int { info[kCGWindowLayer as String] as? Int ?? 0 }
func onscreen(_ info: [String: Any]) -> Bool { (info[kCGWindowIsOnscreen as String] as? Bool) ?? false }
let owned = list.filter { info in
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    let ownerPID = info[kCGWindowOwnerPID as String] as? Int ?? 0
    return ownerPID == pid || owner == "Shiduo" || owner == "拾掇"
}

let chosen: [String: Any]?
if args.contains("--smallest") {
    chosen = owned.filter { layer($0) == 0 && onscreen($0) && width($0) > 300 && height($0) > 200 }
        .min { width($0) * height($0) < width($1) * height($1) }
} else if args.contains("--panel") {
    // 浮在菜单栏上的面板在 CI 上常常没有 onscreen 标记，所以只看层级（> 0）和大小。
    chosen = owned.filter { layer($0) > 0 && width($0) > 200 && height($0) > 60 }
        .max { layer($0) < layer($1) }
} else {
    // 跳过菜单栏那几条 24pt 高的透明窗口（宽度和主窗口一样，会被误选）。
    chosen = owned.filter { layer($0) == 0 && width($0) > 400 && height($0) > 200 }.max { width($0) < width($1) }
}

if let chosen, let id = chosen[kCGWindowNumber as String] as? Int {
    if args.contains("--bounds") {
        let b = bounds(chosen)
        print("\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)),\(Int(b["Width"] ?? 0)),\(Int(b["Height"] ?? 0))")
    } else {
        print(id)
    }
} else {
    var msg = "no window for pid \(pid); windows:\n"
    for info in list where width(info) > 100 {
        msg += "  \(info[kCGWindowOwnerName as String] ?? "?") pid=\(info[kCGWindowOwnerPID as String] ?? "?") layer=\(info[kCGWindowLayer as String] ?? "?") onscreen=\(info[kCGWindowIsOnscreen as String] ?? "?") \(info[kCGWindowBounds as String] ?? "")\n"
    }
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(1)
}
